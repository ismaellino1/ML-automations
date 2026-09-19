-- ============================================================
-- ML AUTOMAÇÕES
-- Migration: 006_appointments_foundation
--
-- Fundação transacional de agendamentos.
--
-- Inclui:
-- - HOLD temporário
-- - confirmação
-- - cancelamento
-- - conclusão / no-show
-- - múltiplos serviços
-- - snapshots históricos
-- - auditoria
-- - buffers
-- - proteção contra horários sobrepostos
-- ============================================================


-- ============================================================
-- 0. EXTENSÃO PARA EXCLUSION CONSTRAINT
-- ============================================================

CREATE EXTENSION IF NOT EXISTS btree_gist
WITH SCHEMA extensions;


-- ============================================================
-- 1. AGENDAMENTOS
-- ============================================================

CREATE TABLE IF NOT EXISTS core.appointments (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    business_id UUID NOT NULL
        REFERENCES core.businesses(id)
        ON DELETE CASCADE,

    customer_id UUID NOT NULL,

    professional_id UUID NOT NULL,

    status VARCHAR(30)
        NOT NULL
        DEFAULT 'HOLD'
        CHECK (
            status IN (
                'HOLD',
                'CONFIRMED',
                'CHECKED_IN',
                'COMPLETED',
                'CANCELLED',
                'NO_SHOW',
                'EXPIRED',
                'RESCHEDULED'
            )
        ),

    -- Horário real do atendimento
    start_at TIMESTAMPTZ NOT NULL,
    end_at TIMESTAMPTZ NOT NULL,

    -- Tempos extras que também bloqueiam agenda
    buffer_before_minutes INTEGER
        NOT NULL
        DEFAULT 0
        CHECK (buffer_before_minutes >= 0),

    buffer_after_minutes INTEGER
        NOT NULL
        DEFAULT 0
        CHECK (buffer_after_minutes >= 0),

    -- Período efetivamente ocupado na agenda.
    -- É mantido automaticamente por trigger.
    blocked_period TSTZRANGE,

    -- Snapshot financeiro
    total_price NUMERIC(10,2)
        NOT NULL
        DEFAULT 0
        CHECK (total_price >= 0),

    currency CHAR(3)
        NOT NULL
        DEFAULT 'BRL',

    total_service_minutes INTEGER
        NOT NULL
        CHECK (total_service_minutes > 0),

    -- HOLD temporário
    hold_expires_at TIMESTAMPTZ,

    confirmed_at TIMESTAMPTZ,
    checked_in_at TIMESTAMPTZ,
    completed_at TIMESTAMPTZ,
    cancelled_at TIMESTAMPTZ,

    cancellation_reason TEXT,

    -- Origem
    source_channel VARCHAR(30),
    source_provider VARCHAR(50),

    metadata JSONB
        NOT NULL
        DEFAULT '{}'::JSONB,

    created_at TIMESTAMPTZ
        NOT NULL
        DEFAULT NOW(),

    updated_at TIMESTAMPTZ
        NOT NULL
        DEFAULT NOW(),

    CONSTRAINT fk_appointments_customer
        FOREIGN KEY (
            business_id,
            customer_id
        )
        REFERENCES core.customers(
            business_id,
            id
        )
        ON DELETE RESTRICT,

    CONSTRAINT fk_appointments_professional
        FOREIGN KEY (
            business_id,
            professional_id
        )
        REFERENCES core.professionals(
            business_id,
            id
        )
        ON DELETE RESTRICT,

    CONSTRAINT chk_appointments_time
        CHECK (
            start_at < end_at
        ),

    CONSTRAINT chk_hold_expiration
        CHECK (
            status <> 'HOLD'
            OR hold_expires_at IS NOT NULL
        ),

    CONSTRAINT chk_hold_expiration_after_creation
        CHECK (
            hold_expires_at IS NULL
            OR hold_expires_at > created_at
        )
);


-- Caso a primeira tentativa tenha criado a tabela
-- antes de falhar, garante que a nova coluna exista.

ALTER TABLE core.appointments
ADD COLUMN IF NOT EXISTS blocked_period TSTZRANGE;


-- ============================================================
-- 2. CHAVE COMPOSTA TENANT-SAFE
-- ============================================================

DO $$
BEGIN

    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conname = 'uq_appointments_business_id_id'
          AND conrelid = 'core.appointments'::regclass
    ) THEN

        ALTER TABLE core.appointments
        ADD CONSTRAINT uq_appointments_business_id_id
        UNIQUE (
            business_id,
            id
        );

    END IF;

END
$$;


-- ============================================================
-- 3. updated_at
-- ============================================================

DROP TRIGGER IF EXISTS trg_appointments_updated_at
ON core.appointments;

CREATE TRIGGER trg_appointments_updated_at
BEFORE UPDATE ON core.appointments
FOR EACH ROW
EXECUTE FUNCTION core.set_updated_at();


-- ============================================================
-- 4. CALCULAR AUTOMATICAMENTE blocked_period
-- ============================================================

CREATE OR REPLACE FUNCTION core.sync_appointment_blocked_period()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN

    NEW.blocked_period := tstzrange(

        NEW.start_at
            - (
                NEW.buffer_before_minutes
                * INTERVAL '1 minute'
            ),

        NEW.end_at
            + (
                NEW.buffer_after_minutes
                * INTERVAL '1 minute'
            ),

        '[)'
    );

    RETURN NEW;

END;
$$;


DROP TRIGGER IF EXISTS trg_appointments_blocked_period
ON core.appointments;


CREATE TRIGGER trg_appointments_blocked_period

BEFORE INSERT OR UPDATE OF
    start_at,
    end_at,
    buffer_before_minutes,
    buffer_after_minutes

ON core.appointments

FOR EACH ROW

EXECUTE FUNCTION core.sync_appointment_blocked_period();


-- Caso existam registros vindos de alguma execução anterior,
-- preenche blocked_period também para eles.

UPDATE core.appointments

SET blocked_period = tstzrange(

    start_at
        - (
            buffer_before_minutes
            * INTERVAL '1 minute'
        ),

    end_at
        + (
            buffer_after_minutes
            * INTERVAL '1 minute'
        ),

    '[)'
);


ALTER TABLE core.appointments
ALTER COLUMN blocked_period
SET NOT NULL;


-- ============================================================
-- 5. PROTEÇÃO CONTRA DUPLA MARCAÇÃO
-- ============================================================
--
-- [) significa:
--
-- 14:00–14:30
-- 14:30–15:00
--
-- podem coexistir normalmente.
--
-- Mas:
--
-- 14:00–14:30
-- 14:15–14:45
--
-- entram em conflito.
-- ============================================================

DO $$
BEGIN

    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conname =
            'excl_appointments_professional_overlap'

          AND conrelid =
            'core.appointments'::regclass
    ) THEN

        ALTER TABLE core.appointments

        ADD CONSTRAINT
            excl_appointments_professional_overlap

        EXCLUDE USING GIST (

            business_id
                WITH =,

            professional_id
                WITH =,

            blocked_period
                WITH &&

        )

        WHERE (
            status IN (
                'HOLD',
                'CONFIRMED',
                'CHECKED_IN'
            )
        );

    END IF;

END
$$;


-- ============================================================
-- 6. ÍNDICES
-- ============================================================

CREATE INDEX IF NOT EXISTS
idx_appointments_business_start

ON core.appointments (
    business_id,
    start_at
);


CREATE INDEX IF NOT EXISTS
idx_appointments_professional_start

ON core.appointments (
    business_id,
    professional_id,
    start_at
);


CREATE INDEX IF NOT EXISTS
idx_appointments_customer_start

ON core.appointments (
    business_id,
    customer_id,
    start_at DESC
);


CREATE INDEX IF NOT EXISTS
idx_appointments_status

ON core.appointments (
    business_id,
    status,
    start_at
);


CREATE INDEX IF NOT EXISTS
idx_appointments_hold_expiration

ON core.appointments (
    hold_expires_at
)

WHERE status = 'HOLD';


-- ============================================================
-- 7. ITENS DO AGENDAMENTO
-- ============================================================

CREATE TABLE IF NOT EXISTS core.appointment_items (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    business_id UUID NOT NULL
        REFERENCES core.businesses(id)
        ON DELETE CASCADE,

    appointment_id UUID NOT NULL,

    service_id UUID NOT NULL,

    -- Snapshots históricos
    service_name_snapshot VARCHAR(150)
        NOT NULL,

    price_snapshot NUMERIC(10,2)
        NOT NULL
        CHECK (price_snapshot >= 0),

    duration_minutes_snapshot INTEGER
        NOT NULL
        CHECK (duration_minutes_snapshot > 0),

    quantity SMALLINT
        NOT NULL
        DEFAULT 1
        CHECK (quantity > 0),

    display_order INTEGER
        NOT NULL
        DEFAULT 0,

    created_at TIMESTAMPTZ
        NOT NULL
        DEFAULT NOW(),

    CONSTRAINT fk_appointment_items_appointment
        FOREIGN KEY (
            business_id,
            appointment_id
        )
        REFERENCES core.appointments(
            business_id,
            id
        )
        ON DELETE CASCADE,

    CONSTRAINT fk_appointment_items_service
        FOREIGN KEY (
            business_id,
            service_id
        )
        REFERENCES core.services(
            business_id,
            id
        )
        ON DELETE RESTRICT
);


CREATE INDEX IF NOT EXISTS
idx_appointment_items_appointment

ON core.appointment_items (
    business_id,
    appointment_id
);


CREATE INDEX IF NOT EXISTS
idx_appointment_items_service

ON core.appointment_items (
    business_id,
    service_id
);


-- ============================================================
-- 8. EVENTOS / AUDITORIA
-- ============================================================

CREATE TABLE IF NOT EXISTS core.appointment_events (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    business_id UUID NOT NULL
        REFERENCES core.businesses(id)
        ON DELETE CASCADE,

    appointment_id UUID NOT NULL,

    event_type VARCHAR(50)
        NOT NULL,

    from_status VARCHAR(30),

    to_status VARCHAR(30),

    actor_type VARCHAR(30),

    actor_ref TEXT,

    payload JSONB
        NOT NULL
        DEFAULT '{}'::JSONB,

    created_at TIMESTAMPTZ
        NOT NULL
        DEFAULT NOW(),

    CONSTRAINT fk_appointment_events_appointment
        FOREIGN KEY (
            business_id,
            appointment_id
        )
        REFERENCES core.appointments(
            business_id,
            id
        )
        ON DELETE CASCADE
);


CREATE INDEX IF NOT EXISTS
idx_appointment_events_appointment

ON core.appointment_events (
    business_id,
    appointment_id,
    created_at
);


CREATE INDEX IF NOT EXISTS
idx_appointment_events_type

ON core.appointment_events (
    business_id,
    event_type,
    created_at
);