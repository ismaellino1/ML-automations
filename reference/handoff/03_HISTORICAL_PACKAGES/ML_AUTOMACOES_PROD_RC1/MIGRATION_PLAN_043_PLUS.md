# Plano de migrations após a 042

A numeração final deve ser definida somente depois de comparar com o banco real.

## Bloco A — Integration Outbox
- tabela/enum de jobs;
- claim lease;
- retry/backoff;
- dead-letter;
- correlation/idempotency;
- functions outbound.

## Bloco B — Calendar Jobs
- adaptar `appointment_calendar_syncs` ou criar outbox genérica;
- geração transacional de CREATE/DELETE no V4;
- completion/failure;
- reconciliação.

## Bloco C — Assistant V4
- `execute_assistant_action_v4`;
- `finalize_assistant_turn_v2`;
- human handoff;
- compatibilidade com toda lógica 001–042.

## Bloco D — Scheduler
- reminders;
- waitlist;
- reactivation/recurrence;
- template-required;
- housekeeping.

## Bloco E — Control Plane / RBAC
- Supabase Auth mapping;
- roles;
- permissions;
- audit log;
- `execute_control_plane_action_v1`;
- tenant onboarding.

## Bloco F — Observability
- incidents;
- job metrics;
- health/usage aggregates necessários ao ML Admin.

## Bloco G — regressão e seed STAGING
Seeds de laboratório ficam fora das migrations de schema de produção.
