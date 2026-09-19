# Best-known database facts observed during STAGING work

Este documento NÃO é um `pg_dump schema-only`. É um snapshot de fatos que foram consultados/confirmados no banco durante a instalação e deve ser usado como evidência complementar.

## Base 001–042

O preflight `supabase/preflight/BASE_001_042_CONTRACT.sql` passou no STAGING restaurado a partir do PROD lógico.

## `core.businesses`

Colunas confirmadas relevantes:

- `id`
- `business_code` (não `code`)
- `name`
- `timezone`
- `locale`
- `status`
- `plan_code`
- `created_at`
- `updated_at`

## `core.business_channels`

Colunas confirmadas:

- `id`
- `business_id`
- `channel_type`
- `provider`
- `external_channel_id`
- `external_account_id`
- `sender_address`
- `credential_key`
- `status`
- `metadata`
- `created_at`
- `updated_at`

## `core.message_delivery_events` real da base V3

Estrutura observada no STAGING antes da 051:

```text
id                    uuid         NOT NULL DEFAULT gen_random_uuid()
business_id           uuid         NOT NULL
provider              varchar      NOT NULL
external_message_id   text         NOT NULL
delivery_status       varchar      NOT NULL
provider_timestamp    timestamptz  NULL
error_detail          text         NULL
raw_payload           jsonb        NOT NULL DEFAULT '{}'::jsonb
event_key             text         NOT NULL UNIQUE
applied_message_id    uuid         NULL
applied_at            timestamptz  NULL
created_at            timestamptz  NOT NULL DEFAULT now()
```

Constraints observadas:

- PK em `id`
- FK `business_id -> core.businesses(id)`
- FK `applied_message_id -> core.messages(id) ON DELETE CASCADE`
- UNIQUE em `event_key`
- CHECK `delivery_status IN ('SENT','DELIVERED','READ','FAILED')`

Índice histórico:

```sql
CREATE INDEX idx_message_delivery_events_pending
ON core.message_delivery_events (business_id,provider,external_message_id,created_at)
WHERE applied_at IS NULL;
```

A migration histórica 027 e funções existentes dependem deste contrato.

## Assinaturas de funções V3 confirmadas

```text
core.execute_assistant_action_v3(
  p_business_id uuid,
  p_conversation_id uuid,
  p_customer_id uuid,
  p_channel_type text,
  p_provider text,
  p_action text,
  p_arguments jsonb
)

core.finalize_assistant_turn(
  p_business_id uuid,
  p_conversation_id uuid,
  p_customer_id uuid,
  p_customer_channel_id uuid,
  p_channel_type text,
  p_provider text,
  p_inbound_message_id uuid,
  p_intent_detected text,
  p_intent_confidence numeric,
  p_kind text,
  p_route text,
  p_action text,
  p_response_text text,
  p_response_type text,
  p_response_source text,
  p_should_send boolean DEFAULT true
)

core.prepare_appointment_cancellation_outbound(
  p_business_id uuid,
  p_appointment_id uuid
)

core.prepare_assistant_turn(
  p_business_code text,
  p_channel_type text,
  p_provider text,
  p_external_user_id text,
  p_idempotency_key text,
  p_external_message_id text,
  p_message_type text,
  p_text_content text,
  p_raw_payload jsonb DEFAULT '{}'::jsonb,
  p_provider_timestamp timestamptz DEFAULT null,
  p_recent_messages_limit int DEFAULT 12
)
```

## Migration 045 campaign statuses

Constraint confirmada como compatível com:

```text
ELIGIBLE
SUPPRESSED
QUEUED
SENT
DELIVERED
READ
FAILED
CONVERTED
```

## Migration 050

Confirmado após aplicação:

- `public.ml_user_businesses`
- RLS habilitado
- policy `ml_user_businesses_self`
- `public.ml_sync_my_memberships()`

## Observação

Se houver qualquer divergência entre este arquivo e introspecção atual do STAGING, a introspecção atual vence.
