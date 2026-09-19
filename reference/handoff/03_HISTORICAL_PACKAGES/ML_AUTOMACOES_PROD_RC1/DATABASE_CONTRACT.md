# ML Automações — Contrato de Banco para PROD RC1

Este arquivo define **o contrato que o Supabase/PostgreSQL precisa cumprir** para os workflows RC1.
Ele não substitui as migrations. A próxima etapa é implementar/atualizar o banco para cumprir este contrato.

## Princípios

- PostgreSQL/Supabase é a fonte de verdade.
- n8n interpreta, orquestra e executa integrações externas.
- Toda mutação crítica deve ser transacional e tenant-safe.
- Toda integração externa deve ser idempotente no lado do Core e recuperável por retry.
- Side effects externos usam outbox/jobs; o fluxo conversacional não chama Calendar ou Meta diretamente.
- `business_id` precisa participar de ownership, constraints, FKs e índices relevantes.
- Claims de workers devem usar lock/lease seguro (`FOR UPDATE SKIP LOCKED` ou equivalente).
- Frontends ML Admin/Manager/Employee nunca decidem autorização: o Core valida RBAC.

## Funções já existentes que podem ser preservadas por baixo da camada V4

- `core.prepare_assistant_turn(...)`
- `core.execute_assistant_action_v3(...)`
- funções de availability, holds, slot offers, confirmação, cancelamento, rebooking e rescheduling
  já consolidadas até a migration 042.
- `core.bind_outbound_external_message(...)`
- funções atuais de calendar sync podem ser reutilizadas internamente.

## Funções que os workflows RC1 esperam

### 1. `core.execute_assistant_action_v4`

```sql
core.execute_assistant_action_v4(
    p_business_id UUID,
    p_conversation_id UUID,
    p_customer_id UUID,
    p_channel_type TEXT,
    p_provider TEXT,
    p_action TEXT,
    p_arguments JSONB,
    p_execution_ref TEXT
) RETURNS JSONB
```

Responsabilidade:
- delegar para a lógica operacional consolidada;
- manter transação/idempotência/locks;
- produzir `execution` canônico;
- quando houver side effects, registrar jobs transacionalmente:
  - Calendar CREATE/DELETE;
  - notificações de cancelamento;
  - demais integrações assíncronas;
- em reschedule, registrar CREATE do replacement e DELETE do source sem depender da execução do n8n naquele turno;
- nunca executar HTTP/Google dentro do PostgreSQL.

### 2. `core.request_human_handoff_v1`

```sql
core.request_human_handoff_v1(
    p_business_id UUID,
    p_conversation_id UUID,
    p_customer_id UUID,
    p_reason TEXT,
    p_execution_ref TEXT
) RETURNS JSONB
```

Deve trocar a automação para HUMAN de forma idempotente e auditar ator/origem.

### 3. `core.finalize_assistant_turn_v2`

```sql
core.finalize_assistant_turn_v2(
    p_business_id UUID,
    p_conversation_id UUID,
    p_customer_id UUID,
    p_customer_channel_id UUID,
    p_channel_type TEXT,
    p_provider TEXT,
    p_inbound_message_id UUID,
    p_intent TEXT,
    p_confidence NUMERIC,
    p_kind TEXT,
    p_route TEXT,
    p_action TEXT,
    p_final_text TEXT,
    p_response_type TEXT,
    p_response_source TEXT,
    p_should_send BOOLEAN,
    p_core_execution JSONB,
    p_execution_ref TEXT
) RETURNS JSONB
```

Deve:
- persistir análise/resposta;
- encerrar/atualizar o turno;
- registrar outbound de forma idempotente quando `p_should_send=true`;
- colocar outbound em estado claimable pelo worker;
- retornar pelo menos `{ok, code, should_send, outbound_message_id}`.

### 4. `core.claim_outbound_delivery_batch`

```sql
core.claim_outbound_delivery_batch(
    p_limit INTEGER,
    p_worker_ref TEXT
) RETURNS TABLE(job JSONB)
```

Cada `job` deve conter:
```json
{
  "job_id": "uuid",
  "business_id": "uuid",
  "internal_message_id": "uuid",
  "phone_number_id": "string",
  "recipient": "string",
  "graph_api_version": "v26.0",
  "delivery_mode": "SESSION|TEMPLATE",
  "meta_payload": {}
}
```

Claim com lease, `SKIP LOCKED`, max attempts, `next_attempt_at` e idempotência.

### 5. `core.complete_outbound_delivery`

```sql
core.complete_outbound_delivery(
    p_job_id UUID,
    p_external_message_id TEXT,
    p_provider_response JSONB
) RETURNS JSONB
```

Marca job/message como SENT e vincula WAMID.

### 6. `core.fail_outbound_delivery`

```sql
core.fail_outbound_delivery(
    p_job_id UUID,
    p_error TEXT,
    p_provider_response JSONB
) RETURNS JSONB
```

Aplica retry/backoff/dead-letter de forma determinística.

### 7. `core.claim_calendar_sync_batch`

```sql
core.claim_calendar_sync_batch(
    p_limit INTEGER,
    p_worker_ref TEXT
) RETURNS TABLE(job JSONB)
```

Job CREATE:
```json
{
  "job_id": "uuid",
  "business_id": "uuid",
  "appointment_id": "uuid",
  "operation": "CREATE",
  "external_calendar_id": "calendar-id",
  "external_event_id": null,
  "start_at": "ISO-8601",
  "end_at": "ISO-8601",
  "summary": "Corte - Cliente | Pedro",
  "description": "...
ML Appointment: <uuid>"
}
```

Job DELETE:
```json
{
  "job_id": "uuid",
  "business_id": "uuid",
  "appointment_id": "uuid",
  "operation": "DELETE",
  "external_calendar_id": "calendar-id",
  "external_event_id": "google-event-id"
}
```

CREATE deve aceitar reconciliação por `appointment_id`. DELETE 404/410 deve ser idempotentemente concluído.

### 8. `core.complete_calendar_sync_job`

```sql
core.complete_calendar_sync_job(
    p_job_id UUID,
    p_external_event_id TEXT,
    p_provider_response JSONB
) RETURNS JSONB
```

### 9. `core.fail_calendar_sync_job`

```sql
core.fail_calendar_sync_job(
    p_job_id UUID,
    p_error TEXT,
    p_provider_response JSONB
) RETURNS JSONB
```

Retry/backoff/dead-letter. Falha de DELETE antigo não deve desfazer appointment novo já confirmado.

### 10. `core.enqueue_due_automation_jobs`

```sql
core.enqueue_due_automation_jobs(
    p_limit INTEGER,
    p_execution_ref TEXT
) RETURNS JSONB
```

Abrange, respeitando configurações do tenant:
- lembretes de appointment;
- waitlist;
- recorrência/reativação;
- notificações pendentes de cancelamento;
- mensagens TEMPLATE_REQUIRED quando houver template aprovado/configurado;
- outros jobs agendados explicitamente habilitados.

### 11. `core.run_housekeeping_v1`

```sql
core.run_housekeeping_v1(
    p_limit INTEGER,
    p_execution_ref TEXT
) RETURNS JSONB
```

Abrange:
- expirar holds;
- expirar slot offers;
- liberar claims/leases órfãos;
- reprogramar jobs recuperáveis;
- marcar dead-letter quando exceder política;
- limpeza/retention conforme política, sem apagar trilha de auditoria necessária.

### 12. `core.execute_control_plane_action_v1`

```sql
core.execute_control_plane_action_v1(
    p_actor_user_id UUID,
    p_business_id UUID,
    p_role TEXT,
    p_action TEXT,
    p_arguments JSONB,
    p_idempotency_key TEXT,
    p_execution_ref TEXT
) RETURNS JSONB
```

É a fronteira operacional para ML Admin / ML Manager / ML Employee.

RBAC mínimo canônico:
- `PLATFORM_ADMIN`
- `OWNER`
- `MANAGER`
- `RECEPTIONIST`
- `BARBER`

O Core deve ignorar `p_role` como prova de autorização e derivar/validar a role real do usuário no banco.

Ações iniciais:
- onboarding/ativação de tenant (somente plataforma);
- cancelamento por PROFESSIONAL/BUSINESS com motivo público;
- bloqueio/desbloqueio de agenda;
- ações administrativas de appointment;
- configurações permitidas de serviço/equipe/agenda;
- handoff AUTO/HUMAN;
- integrações e validações de configuração.

Toda ação mutável precisa de auditoria e idempotency key.

### 13. `core.record_automation_incident_v1`

```sql
core.record_automation_incident_v1(
    p_incident JSONB
) RETURNS JSONB
```

Persistir workflow, execution id, node, erro, timestamps, correlação e severidade calculada.
Deve permitir futura tela de incidentes no ML Admin.

## Estruturas novas recomendadas na próxima migration

- `core.integration_jobs`
- `core.outbound_delivery_jobs` (ou outbox unificada)
- `core.automation_incidents`
- `core.user_business_roles`
- `core.role_permissions`
- `core.audit_log`
- `core.tenant_onboarding_runs`
- `core.feature_flags`
- `core.integration_credentials_metadata` (somente metadados; segredos fora de texto puro)
- índices por `(business_id, status, next_attempt_at)`
- unique/idempotency constraints por operação lógica

## ML Admin / Manager / Employee

A plataforma deve usar um backend/API confiável + Supabase Auth. O frontend não chama tabelas sensíveis
sem política/endpoint de autorização.

Superfícies:
- **ML Admin**: tenants, onboarding, integrações, incidentes, uso, planos/billing futuro, suporte, auditoria.
- **ML Manager**: agenda da empresa, serviços, equipe, horários, clientes, automações, integrações, relatórios.
- **ML Employee**: agenda própria, atendimentos, bloqueios permitidos, status e dados mínimos necessários.

Não são três bancos nem três cópias do produto: são superfícies distintas sobre o mesmo Core multi-tenant.
