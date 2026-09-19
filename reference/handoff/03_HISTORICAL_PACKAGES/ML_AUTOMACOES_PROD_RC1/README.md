# ML AUTOMAÇÕES — PROD RC1

Este pacote é uma **nova arquitetura de produção**, não uma tentativa de remendar o V3 anterior.

O V3 antigo serviu como fonte de contratos já testados (WhatsApp, IA, Core, slots, rebooking,
rescheduling e Calendar), mas os workflows RC1 foram organizados para remover o principal risco
do desenho anterior: side effects externos misturados ao turno conversacional.

## Arquitetura

```text
WhatsApp
   │
   ▼
01 - ML CORE - UNIVERSAL PROD
   │
   ├─ PostgreSQL Core (verdade operacional)
   │
   ├─ registra outbound
   │
   └─ registra side effects
          │
          ├──────────────► 02 - WhatsApp Outbox Worker ─► Meta
          └──────────────► 03 - Calendar Worker ─────────► Google Calendar

04 - Scheduler ─► reminders / waitlist / reactivation / housekeeping
05 - Control Plane ─► futuro ML Admin / ML Manager / ML Employee
99 - Error ─► incidentes/observabilidade
```

## O que foi eliminado de propósito

- DEV trigger dentro do runtime de produção;
- telefone de cliente hardcoded;
- business/appointment UUID hardcoded;
- bloco 24→27 órfão;
- Calendar disparado diretamente do turno do cliente;
- duplicidade de node Meta nativo + HTTP;
- query inválida no antigo node de falha Calendar;
- expressões `=={{`;
- configuração por cópia de workflow por cliente;
- decisões de negócio dentro do n8n.

## 01 — CORE UNIVERSAL

O fluxo:
1. recebe Meta/WhatsApp;
2. normaliza evento/interações;
3. chama `prepare_assistant_turn`;
4. bloqueia duplicidade;
5. diferencia interação estruturada de linguagem natural;
6. usa IA Orquestradora com JSON Schema rígido;
7. valida o comando antes do Core;
8. executa Core V4;
9. trata handoff real;
10. produz resposta com Response Engine;
11. possui fallback determinístico se a IA de resposta falhar;
12. finaliza o turno;
13. registra outbound na outbox.

**Não envia Meta nem mexe no Google Calendar diretamente.**

## 02 — WHATSAPP OUTBOX WORKER

- polling em lote;
- claim/lease no banco;
- payload Meta já canônico;
- envio por credencial n8n;
- bind do WAMID;
- retry/backoff/dead-letter decidido no Core;
- serve tanto resposta conversacional quanto cancelamento profissional/empresa, reminders etc.

## 03 — GOOGLE CALENDAR WORKER

CREATE:
- procura evento existente pelo appointment_id antes de criar;
- reconcilia retries;
- cria apenas quando não existe;
- registra external_event_id.

DELETE:
- idempotente;
- 404/410 = sucesso lógico ("já não existe");
- demais falhas voltam ao Core para retry.

Reschedule não depende mais de ligação `delete → create` no canvas.
O banco cria dois jobs correlacionados e o estado do appointment continua sendo a verdade.

## 04 — SCHEDULER

- 1 minuto: enqueue de automações devidas;
- 5 minutos: housekeeping;
- reminders, waitlist e reactivation continuam configuráveis por tenant no banco.

## 05 — CONTROL PLANE

Fronteira interna para o futuro:
- ML Admin;
- ML Manager;
- ML Employee.

**Deve permanecer inativo até receber uma credencial n8n do tipo `Header Auth`
com nome `ML Internal API Auth`.**

A autorização real continua no Core; o header apenas protege o endpoint de automação.

## 99 — OBSERVABILITY

Error Trigger centraliza falhas do n8n no Core para que o ML Admin tenha futuramente:
- incidentes;
- workflow;
- execution id;
- node;
- erro;
- correlação;
- histórico.

## Credenciais

Os workflows preservam referências às credenciais já usadas no projeto quando aplicável:
- PostgreSQL;
- WhatsApp Meta;
- Google Calendar;
- OpenAI via gateway gerenciado.

Ao importar em outra instância, reatribua as credenciais.

## O que falta

A parte principal que falta é o **Supabase/PostgreSQL cumprir o contrato em
`DATABASE_CONTRACT.md`**, via novas migrations a partir do estado atual.

Depois:
1. importar os workflows em STAGING;
2. apontar as credenciais;
3. executar migrations;
4. fazer bateria E2E;
5. corrigir somente falha demonstrada;
6. congelar release;
7. construir ML Admin/Manager/Employee sobre o Control Plane/Core.

## Regra de release

Nenhum workflow deve ser ativado em PROD apenas porque importou.
A condição de release é passar a matriz `TEST_MATRIX.md`.
