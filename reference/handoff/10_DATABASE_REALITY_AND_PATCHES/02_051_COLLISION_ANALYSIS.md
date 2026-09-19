# Migration 051 — known deterministic compatibility collision

## Situação

A migration original `051_whatsapp_calendar_hardening.sql` contém:

```sql
CREATE TABLE IF NOT EXISTS core.message_delivery_events (
    id BIGSERIAL PRIMARY KEY,
    business_id UUID NOT NULL,
    message_id UUID NOT NULL,
    provider VARCHAR(50) NOT NULL,
    external_message_id TEXT,
    delivery_status VARCHAR(30) NOT NULL,
    provider_timestamp TIMESTAMPTZ,
    payload JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT fk_delivery_event_message
        FOREIGN KEY (business_id, message_id)
        REFERENCES core.messages(business_id, id)
        ON DELETE CASCADE
);
```

Porém a base 001–042 já possui `core.message_delivery_events` criada pela messaging engine histórica com contrato diferente (ver `01_KNOWN_DATABASE_FACTS.md`).

`CREATE TABLE IF NOT EXISTS` não migra uma tabela já existente.

Mais adiante, 051 cria `core.ingest_whatsapp_delivery_status_v1` com INSERT que assume colunas inexistentes:

```sql
INSERT INTO core.message_delivery_events(
    business_id,
    message_id,
    provider,
    external_message_id,
    delivery_status,
    provider_timestamp,
    payload
)
```

Problemas objetivos:

- `message_id` não existe no contrato real;
- `payload` não existe; o campo real é `raw_payload`;
- a tabela real exige `event_key NOT NULL`;
- a base histórica possui `applied_message_id`/`applied_at` e funções que usam essa semântica;
- simplesmente adicionar as colunas novas pode criar duas semânticas concorrentes para a mesma tabela.

## Instrução ao Claude

Não aplique a 051 original cegamente e não apague/recrie a tabela histórica.

Primeiro:

1. leia a migration 027;
2. inspecione as funções históricas de delivery receipt (`apply_message_delivery_status` / bind/replay, se presentes);
3. derive a assinatura e semântica reais;
4. adapte 051 para reutilizar o contrato existente ou crie migration corretiva explícita;
5. preserve idempotência de receipts e compatibilidade com pending receipts;
6. teste receipt antes/depois do bind da mensagem outbound;
7. teste evento duplicado e evento fora de ordem;
8. verifique tenant isolation.

A 051 não foi considerada aplicada no estado registrado neste handoff.
