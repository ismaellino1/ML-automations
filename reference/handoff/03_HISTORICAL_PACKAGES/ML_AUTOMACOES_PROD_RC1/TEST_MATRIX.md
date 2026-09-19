# Matriz E2E — ML Automações PROD RC1

## Entrada e idempotência
- mesma mensagem Meta recebida 2x → um único turno processado;
- retry do webhook → nenhuma duplicação de appointment/outbound;
- evento Meta sem `messages` → não cria mutação;
- mensagem vazia/estranha → resposta segura, sem ação operacional.

## IA e interpretação
- gírias, abreviações e erros;
- correção de data/profissional no turno seguinte;
- mensagem ambígua com dois appointments → pede referência;
- serviço/profissional inexistente → nunca inventa ID;
- OpenAI Orchestrator indisponível → nenhuma BUSINESS_ACTION é executada;
- OpenAI Response Engine indisponível → fallback determinístico usa fatos do Core.

## Booking
- busca normal;
- qualquer profissional;
- preferência com fallback;
- 1–3 slots → botões;
- 4–10 slots → lista;
- clique válido;
- clique repetido;
- clique em offer expirada;
- clique em lista antiga com offer nova;
- concorrência de dois clientes no mesmo slot;
- hold expirado;
- confirmação idempotente.

## GET / Cancel / Rebook / Reschedule
- consultar appointment;
- cancelar pelo cliente;
- cancelar novamente;
- cancelamento por professional/business via Control Plane;
- motivo público;
- rebooking de CANCELLED;
- reschedule de CONFIRMED;
- tentativa de RESCHEDULE em CANCELLED rejeitada;
- seleção de slot de reschedule;
- lineage source ↔ replacement.

## WhatsApp outbound
- session message;
- interactive list/buttons;
- template-required fora da janela;
- falha Meta 5xx → retry/backoff;
- falha permanente → dead-letter;
- WAMID vinculado uma única vez;
- cancelamento profissional/empresa dispara notificação por outbox.

## Google Calendar
- CREATE normal;
- retry após Google criar e antes do Core marcar → reconcilia, não duplica;
- DELETE normal;
- DELETE de evento já removido → sucesso lógico;
- falha Google temporária → retry;
- reschedule cria evento replacement e remove source de forma eventual;
- calendar errado/sem permissão → incident + retry/dead-letter, sem corromper appointment.

## Scheduler
- reminder devido;
- reminder já enviado;
- waitlist;
- reactivation/recurrence habilitada;
- tenant com automação desabilitada;
- expiração de holds/offers;
- liberação de claim órfão.

## Human handoff
- cliente pede humano;
- conversa muda para HUMAN;
- automação não volta sozinha sem regra explícita;
- auditoria contém motivo/origem.

## Multi-tenant
- cliente A nunca enxerga serviço/profissional/appointment de B;
- mesma external_user_id em tenants diferentes;
- calendar por profissional/tenant;
- idempotency keys escopadas corretamente;
- jobs nunca atravessam business_id.

## Control Plane / RBAC
- PLATFORM_ADMIN;
- OWNER;
- MANAGER;
- RECEPTIONIST;
- BARBER;
- ação não permitida retorna erro sem mutação;
- role enviada pelo cliente não substitui role real do banco;
- idempotency key repetida não duplica ação.

## Observabilidade
- erro em cada workflow aparece em automation_incidents;
- execution id e workflow registrados;
- retry/dead-letter visível;
- ausência do banco não é mascarada como sucesso.

## Critério de release
Zero falha crítica em:
- isolamento de tenant;
- duplicação de appointment;
- duplicação de Calendar;
- autorização/RBAC;
- cancelamento/reschedule/rebook;
- idempotência de inbound;
- persistência de outbound.
