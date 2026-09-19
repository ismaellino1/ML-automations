-- ============================================================
-- ML AUTOMAÇÕES
-- Migration: 007_messaging_foundation
--
-- Fundação da camada de mensagens e conversas.
--
-- Inclui:
-- - canais pertencentes ao estabelecimento
-- - conversas multi-canal
-- - modo automático / humano
-- - estado flexível da conversa
-- - slots estruturados
-- - histórico de mensagens
-- - idempotência
-- - status de processamento
-- - status de entrega
-- - versionamento para concorrência
-- ============================================================


-- ============================================================
-- 1. CANAIS DO ESTABELECIMENTO
-- ============================================================
--
-- Exemplos:
--
-- Barbearia A
--   WHATSAPP / META_CLOUD / phone_number_id 123...
--
-- Barbearia B
--   WHATSAPP / OUTRO_PROVIDER / numero xyz...
--
-- Isso permite descobrir business_id a partir
-- do evento recebido pelo adapter.
-- ============================================================

CREATE TABLE IF NOT EXISTS core.business_channels (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    business_id UUID NOT NULL
        REFERENCES core.businesses(id)
        ON DELETE CASCADE,

    channel_type VARCHAR(30)
        NOT NULL
        CHECK (
            channel_type IN (
                'WHATSAPP',
                'INSTAGRAM',
                'WEB',
                'TELEGRAM',
                'OTHER'
            )
        ),

    provider VARCHAR(50)
        NOT NULL,

    -- Identificador técnico do canal no provider.
    --
    -- Meta WhatsApp:
    -- phone_number_id
    --
    -- Outro provider:
    -- identificador equivalente.
    external_channel_id TEXT
        NOT NULL,

    -- Exemplo:
    -- WABA ID da Meta.
    external_account_id TEXT,

    -- Número ou endereço amigável para exibição.
    sender_address TEXT,

    -- Apenas referência lógica para uma credencial.
    -- NÃO armazenar token, senha ou segredo aqui.
    credential_key TEXT,

    status VARCHAR(30)
        NOT NULL
        DEFAULT 'ACTIVE'
        CHECK (
            status IN (
                'ACTIVE',
                'PAUSED',
                'DISCONNECTED',
                'ARCHIVED'
            )
        ),

    metadata JSONB
        NOT NULL
        DEFAULT '{}'::JSONB,

    created_at TIMESTAMPTZ
        NOT NULL
        DEFAULT NOW(),

    updated_at TIMESTAMPTZ
        NOT NULL
        DEFAULT NOW(),

    CONSTRAINT uq_business_channel_provider_external
        UNIQUE (
            provider,
            external_channel_id
        )
);


DO $$
BEGIN

    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conname = 'uq_business_channels_business_id_id'
          AND conrelid = 'core.business_channels'::regclass
    ) THEN

        ALTER TABLE core.business_channels
        ADD CONSTRAINT uq_business_channels_business_id_id
        UNIQUE (
            business_id,
            id
        );

    END IF;

END
$$;


DROP TRIGGER IF EXISTS trg_business_channels_updated_at
ON core.business_channels;

CREATE TRIGGER trg_business_channels_updated_at
BEFORE UPDATE ON core.business_channels
FOR EACH ROW
EXECUTE FUNCTION core.set_updated_at();


CREATE INDEX IF NOT EXISTS idx_business_channels_business
ON core.business_channels (
    business_id,
    status
);


CREATE INDEX IF NOT EXISTS idx_business_channels_lookup
ON core.business_channels (
    provider,
    external_channel_id
);


-- ============================================================
-- 2. GARANTIR CHAVE COMPOSTA EM customer_channels
-- ============================================================
--
-- Necessária para FKs tenant-safe abaixo.
-- ============================================================

DO $$
BEGIN

    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conname = 'uq_customer_channels_business_id_id'
          AND conrelid = 'core.customer_channels'::regclass
    ) THEN

        ALTER TABLE core.customer_channels
        ADD CONSTRAINT uq_customer_channels_business_id_id
        UNIQUE (
            business_id,
            id
        );

    END IF;

END
$$;


-- ============================================================
-- 3. CONVERSAS
-- ============================================================

CREATE TABLE IF NOT EXISTS core.conversations (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    business_id UUID NOT NULL
        REFERENCES core.businesses(id)
        ON DELETE CASCADE,

    customer_id UUID NOT NULL,

    business_channel_id UUID NOT NULL,

    customer_channel_id UUID NOT NULL,

    status VARCHAR(20)
        NOT NULL
        DEFAULT 'OPEN'
        CHECK (
            status IN (
                'OPEN',
                'CLOSED'
            )
        ),

    -- Quem está controlando a conversa?
    automation_mode VARCHAR(20)
        NOT NULL
        DEFAULT 'AUTO'
        CHECK (
            automation_mode IN (
                'AUTO',
                'HUMAN'
            )
        ),

    -- Exemplo:
    -- BOOK
    -- CANCEL
    -- RESCHEDULE
    -- FAQ
    -- WAITLIST
    current_intent VARCHAR(50),

    -- Exemplo:
    -- WAITING_CONFIRMATION
    -- WAITING_MISSING_DATA
    --
    -- Não será nossa máquina rígida principal.
    -- É apenas uma pista operacional.
    pending_action VARCHAR(50),

    -- Dados que a conversa já possui.
    --
    -- Exemplo:
    --
    -- {
    --   "service_id": "...",
    --   "professional_id": "...",
    --   "date": "2026-09-15",
    --   "time_from": "17:00"
    -- }
    slots JSONB
        NOT NULL
        DEFAULT '{}'::JSONB,

    -- Contexto técnico adicional.
    context JSONB
        NOT NULL
        DEFAULT '{}'::JSONB,

    -- Resumo textual condensado para IA,
    -- sem precisar enviar toda a conversa sempre.
    context_summary TEXT,

    -- Usado depois para optimistic locking.
    version INTEGER
        NOT NULL
        DEFAULT 1
        CHECK (version > 0),

    opened_at TIMESTAMPTZ
        NOT NULL
        DEFAULT NOW(),

    closed_at TIMESTAMPTZ,

    last_message_at TIMESTAMPTZ,

    last_inbound_at TIMESTAMPTZ,

    last_outbound_at TIMESTAMPTZ,

    session_expires_at TIMESTAMPTZ,

    created_at TIMESTAMPTZ
        NOT NULL
        DEFAULT NOW(),

    updated_at TIMESTAMPTZ
        NOT NULL
        DEFAULT NOW(),

    CONSTRAINT fk_conversations_customer
        FOREIGN KEY (
            business_id,
            customer_id
        )
        REFERENCES core.customers(
            business_id,
            id
        )
        ON DELETE RESTRICT,

    CONSTRAINT fk_conversations_business_channel
        FOREIGN KEY (
            business_id,
            business_channel_id
        )
        REFERENCES core.business_channels(
            business_id,
            id
        )
        ON DELETE RESTRICT,

    CONSTRAINT fk_conversations_customer_channel
        FOREIGN KEY (
            business_id,
            customer_channel_id
        )
        REFERENCES core.customer_channels(
            business_id,
            id
        )
        ON DELETE RESTRICT,

    CONSTRAINT chk_conversation_closed_at
        CHECK (
            status <> 'CLOSED'
            OR closed_at IS NOT NULL
        )
);


DO $$
BEGIN

    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conname = 'uq_conversations_business_id_id'
          AND conrelid = 'core.conversations'::regclass
    ) THEN

        ALTER TABLE core.conversations
        ADD CONSTRAINT uq_conversations_business_id_id
        UNIQUE (
            business_id,
            id
        );

    END IF;

END
$$;


-- ============================================================
-- 4. VERSIONAMENTO + updated_at
-- ============================================================

CREATE OR REPLACE FUNCTION core.touch_conversation()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN

    NEW.updated_at := NOW();

    NEW.version := OLD.version + 1;

    RETURN NEW;

END;
$$;


DROP TRIGGER IF EXISTS trg_conversations_touch
ON core.conversations;


CREATE TRIGGER trg_conversations_touch
BEFORE UPDATE ON core.conversations
FOR EACH ROW
EXECUTE FUNCTION core.touch_conversation();


-- ============================================================
-- 5. UMA CONVERSA ABERTA POR CANAL/CLIENTE
-- ============================================================

CREATE UNIQUE INDEX IF NOT EXISTS
uq_open_conversation_per_channel

ON core.conversations (
    business_id,
    business_channel_id,
    customer_channel_id
)

WHERE status = 'OPEN';


CREATE INDEX IF NOT EXISTS idx_conversations_customer
ON core.conversations (
    business_id,
    customer_id,
    updated_at DESC
);


CREATE INDEX IF NOT EXISTS idx_conversations_open
ON core.conversations (
    business_id,
    status,
    last_message_at DESC
);


CREATE INDEX IF NOT EXISTS idx_conversations_human
ON core.conversations (
    business_id,
    automation_mode,
    last_message_at DESC
)

WHERE status = 'OPEN';


-- ============================================================
-- 6. MENSAGENS
-- ============================================================

CREATE TABLE IF NOT EXISTS core.messages (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    business_id UUID NOT NULL
        REFERENCES core.businesses(id)
        ON DELETE CASCADE,

    conversation_id UUID NOT NULL,

    customer_id UUID NOT NULL,

    customer_channel_id UUID NOT NULL,

    direction VARCHAR(20)
        NOT NULL
        CHECK (
            direction IN (
                'INBOUND',
                'OUTBOUND',
                'SYSTEM'
            )
        ),

    channel_type VARCHAR(30)
        NOT NULL,

    provider VARCHAR(50)
        NOT NULL,

    -- Nossa chave canônica de idempotência.
    --
    -- Exemplo:
    -- META_CLOUD:wamid.HBg...
    --
    -- Isso substitui aquela tabela de
    -- mensagens_processadas da V1.
    idempotency_key TEXT
        NOT NULL,

    -- ID recebido/devolvido pelo provider.
    external_message_id TEXT,

    reply_to_external_message_id TEXT,

    message_type VARCHAR(30)
        NOT NULL
        DEFAULT 'TEXT',

    text_content TEXT,

    -- Payload original recebido do provider.
    raw_payload JSONB
        NOT NULL
        DEFAULT '{}'::JSONB,

    -- Versão normalizada pelo nosso adapter.
    canonical_payload JSONB
        NOT NULL
        DEFAULT '{}'::JSONB,

    processing_status VARCHAR(30)
        NOT NULL
        DEFAULT 'RECEIVED'
        CHECK (
            processing_status IN (
                'RECEIVED',
                'PROCESSING',
                'PROCESSED',
                'FAILED',
                'IGNORED'
            )
        ),

    processing_error TEXT,

    -- Resultado da camada de interpretação.
    intent_detected VARCHAR(50),

    intent_confidence NUMERIC(5,4)
        CHECK (
            intent_confidence IS NULL
            OR (
                intent_confidence >= 0
                AND intent_confidence <= 1
            )
        ),

    -- Estado de entrega do canal.
    delivery_status VARCHAR(30)
        NOT NULL
        DEFAULT 'NOT_APPLICABLE'
        CHECK (
            delivery_status IN (
                'NOT_APPLICABLE',
                'QUEUED',
                'SENT',
                'DELIVERED',
                'READ',
                'FAILED'
            )
        ),

    provider_timestamp TIMESTAMPTZ,

    processed_at TIMESTAMPTZ,

    sent_at TIMESTAMPTZ,

    created_at TIMESTAMPTZ
        NOT NULL
        DEFAULT NOW(),

    updated_at TIMESTAMPTZ
        NOT NULL
        DEFAULT NOW(),

    CONSTRAINT fk_messages_conversation
        FOREIGN KEY (
            business_id,
            conversation_id
        )
        REFERENCES core.conversations(
            business_id,
            id
        )
        ON DELETE CASCADE,

    CONSTRAINT fk_messages_customer
        FOREIGN KEY (
            business_id,
            customer_id
        )
        REFERENCES core.customers(
            business_id,
            id
        )
        ON DELETE RESTRICT,

    CONSTRAINT fk_messages_customer_channel
        FOREIGN KEY (
            business_id,
            customer_channel_id
        )
        REFERENCES core.customer_channels(
            business_id,
            id
        )
        ON DELETE RESTRICT,

    CONSTRAINT uq_messages_idempotency
        UNIQUE (
            business_id,
            idempotency_key
        )
);


DROP TRIGGER IF EXISTS trg_messages_updated_at
ON core.messages;

CREATE TRIGGER trg_messages_updated_at
BEFORE UPDATE ON core.messages
FOR EACH ROW
EXECUTE FUNCTION core.set_updated_at();


-- ============================================================
-- 7. ID EXTERNO DO PROVIDER NÃO PODE DUPLICAR
-- ============================================================

CREATE UNIQUE INDEX IF NOT EXISTS
uq_messages_provider_external_id

ON core.messages (
    business_id,
    provider,
    external_message_id
)

WHERE external_message_id IS NOT NULL;


-- ============================================================
-- 8. ÍNDICES DE MENSAGENS
-- ============================================================

CREATE INDEX IF NOT EXISTS idx_messages_conversation
ON core.messages (
    business_id,
    conversation_id,
    created_at
);


CREATE INDEX IF NOT EXISTS idx_messages_customer
ON core.messages (
    business_id,
    customer_id,
    created_at DESC
);


CREATE INDEX IF NOT EXISTS idx_messages_processing
ON core.messages (
    business_id,
    processing_status,
    created_at
);


CREATE INDEX IF NOT EXISTS idx_messages_delivery
ON core.messages (
    business_id,
    delivery_status,
    created_at
)

WHERE direction = 'OUTBOUND';