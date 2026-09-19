-- ============================================================
-- 035_appointment_cancellation_foundation
-- ============================================================


-- ============================================================
-- 1. AUDITORIA DE CANCELAMENTOS
-- ============================================================

CREATE TABLE IF NOT EXISTS core.appointment_cancellations (

    id UUID PRIMARY KEY
        DEFAULT gen_random_uuid(),

    business_id UUID NOT NULL,

    appointment_id UUID NOT NULL,

    customer_id UUID NOT NULL,

    professional_id UUID NOT NULL,

    -- Quem iniciou o cancelamento:
    -- CUSTOMER | PROFESSIONAL | BUSINESS | SYSTEM
    actor_type VARCHAR(20) NOT NULL,

    actor_customer_id UUID NULL,

    actor_professional_id UUID NULL,

    -- Identificador livre para futuro ML Admin,
    -- funcionário, integração etc.
    actor_ref TEXT NULL,

    -- Motivo que pode ser comunicado ao cliente.
    public_reason TEXT NULL,

    -- Informação interna que NÃO precisa ser enviada ao cliente.
    internal_reason TEXT NULL,

    source_channel VARCHAR(50) NULL,

    source_provider VARCHAR(50) NULL,


    -- ========================================================
    -- CONTROLE DA NOTIFICAÇÃO AO CLIENTE
    -- ========================================================

    customer_notification_required BOOLEAN NOT NULL
        DEFAULT TRUE,

    customer_notification_status VARCHAR(20) NOT NULL
        DEFAULT 'PENDING',

    customer_notification_message_id UUID NULL,

    customer_notified_at TIMESTAMPTZ NULL,

    notification_error TEXT NULL,


    cancelled_at TIMESTAMPTZ NOT NULL
        DEFAULT NOW(),

    created_at TIMESTAMPTZ NOT NULL
        DEFAULT NOW(),

    updated_at TIMESTAMPTZ NOT NULL
        DEFAULT NOW(),


    CONSTRAINT appointment_cancellations_appointment_fk
        FOREIGN KEY (
            business_id,
            appointment_id
        )
        REFERENCES core.appointments (
            business_id,
            id
        )
        ON DELETE CASCADE,


    CONSTRAINT appointment_cancellations_customer_fk
        FOREIGN KEY (
            business_id,
            customer_id
        )
        REFERENCES core.customers (
            business_id,
            id
        )
        ON DELETE RESTRICT,


    CONSTRAINT appointment_cancellations_professional_fk
        FOREIGN KEY (
            business_id,
            professional_id
        )
        REFERENCES core.professionals (
            business_id,
            id
        )
        ON DELETE RESTRICT,


    CONSTRAINT appointment_cancellations_actor_customer_fk
        FOREIGN KEY (
            business_id,
            actor_customer_id
        )
        REFERENCES core.customers (
            business_id,
            id
        )
        ON DELETE RESTRICT,


    CONSTRAINT appointment_cancellations_actor_professional_fk
        FOREIGN KEY (
            business_id,
            actor_professional_id
        )
        REFERENCES core.professionals (
            business_id,
            id
        )
        ON DELETE RESTRICT,


    CONSTRAINT appointment_cancellations_message_fk
        FOREIGN KEY (
            customer_notification_message_id
        )
        REFERENCES core.messages(id)
        ON DELETE SET NULL,


    CONSTRAINT appointment_cancellations_actor_type_chk
        CHECK (
            actor_type IN (
                'CUSTOMER',
                'PROFESSIONAL',
                'BUSINESS',
                'SYSTEM'
            )
        ),


    CONSTRAINT appointment_cancellations_notification_status_chk
        CHECK (
            customer_notification_status IN (
                'PENDING',
                'SENT',
                'FAILED',
                'NOT_REQUIRED'
            )
        ),


    CONSTRAINT appointment_cancellations_actor_identity_chk
        CHECK (

            (
                actor_type = 'CUSTOMER'
                AND actor_customer_id IS NOT NULL
            )

            OR

            (
                actor_type = 'PROFESSIONAL'
                AND actor_professional_id IS NOT NULL
            )

            OR

            actor_type IN (
                'BUSINESS',
                'SYSTEM'
            )
        ),


    -- Profissional ou empresa não pode cancelar silenciosamente.
    CONSTRAINT appointment_cancellations_reason_chk
        CHECK (

            actor_type NOT IN (
                'PROFESSIONAL',
                'BUSINESS'
            )

            OR

            NULLIF(
                BTRIM(public_reason),
                ''
            ) IS NOT NULL
        ),


    CONSTRAINT appointment_cancellations_unique
        UNIQUE (
            business_id,
            appointment_id
        )
);


CREATE INDEX IF NOT EXISTS
idx_appointment_cancellations_customer
ON core.appointment_cancellations (
    business_id,
    customer_id,
    cancelled_at DESC
);


CREATE INDEX IF NOT EXISTS
idx_appointment_cancellations_professional
ON core.appointment_cancellations (
    business_id,
    professional_id,
    cancelled_at DESC
);


CREATE INDEX IF NOT EXISTS
idx_appointment_cancellations_notification
ON core.appointment_cancellations (
    business_id,
    customer_notification_status
)
WHERE customer_notification_required = TRUE;



-- ============================================================
-- 2. CANCELAMENTO TRANSACIONAL
-- ============================================================

CREATE OR REPLACE FUNCTION core.cancel_appointment(
    p_business_id UUID,
    p_appointment_id UUID,
    p_actor_type TEXT,

    p_actor_customer_id UUID DEFAULT NULL,
    p_actor_professional_id UUID DEFAULT NULL,
    p_actor_ref TEXT DEFAULT NULL,

    p_public_reason TEXT DEFAULT NULL,
    p_internal_reason TEXT DEFAULT NULL,

    p_source_channel TEXT DEFAULT NULL,
    p_source_provider TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
VOLATILE
AS $$
DECLARE

    v_appointment core.appointments%ROWTYPE;

    v_settings core.business_settings%ROWTYPE;

    v_business core.businesses%ROWTYPE;

    v_cancellation core.appointment_cancellations%ROWTYPE;

    v_calendar_sync core.appointment_calendar_syncs%ROWTYPE;

    v_actor_type TEXT;

    v_public_reason TEXT;

    v_internal_reason TEXT;

    v_cancellation_deadline TIMESTAMPTZ;

    v_calendar_delete_required BOOLEAN := FALSE;

BEGIN

    v_actor_type :=
        UPPER(
            BTRIM(
                COALESCE(
                    p_actor_type,
                    ''
                )
            )
        );


    v_public_reason :=
        NULLIF(
            BTRIM(
                COALESCE(
                    p_public_reason,
                    ''
                )
            ),
            ''
        );


    v_internal_reason :=
        NULLIF(
            BTRIM(
                COALESCE(
                    p_internal_reason,
                    ''
                )
            ),
            ''
        );


    -- ========================================================
    -- VALIDAR ACTOR TYPE
    -- ========================================================

    IF v_actor_type NOT IN (
        'CUSTOMER',
        'PROFESSIONAL',
        'BUSINESS',
        'SYSTEM'
    )
    THEN

        RETURN JSONB_BUILD_OBJECT(
            'ok', FALSE,
            'code', 'INVALID_CANCELLATION_ACTOR'
        );

    END IF;


    -- ========================================================
    -- CARREGAR EMPRESA
    -- ========================================================

    SELECT b.*
    INTO v_business

    FROM core.businesses b

    WHERE b.id = p_business_id

    LIMIT 1;


    IF NOT FOUND
    THEN

        RETURN JSONB_BUILD_OBJECT(
            'ok', FALSE,
            'code', 'BUSINESS_NOT_FOUND'
        );

    END IF;


    -- ========================================================
    -- BLOQUEAR APPOINTMENT DURANTE A TRANSAÇÃO
    -- ========================================================

    SELECT a.*
    INTO v_appointment

    FROM core.appointments a

    WHERE a.business_id = p_business_id
      AND a.id = p_appointment_id

    FOR UPDATE;


    IF NOT FOUND
    THEN

        RETURN JSONB_BUILD_OBJECT(
            'ok', FALSE,
            'code', 'APPOINTMENT_NOT_FOUND'
        );

    END IF;


    -- ========================================================
    -- IDEMPOTÊNCIA
    -- ========================================================

    IF v_appointment.status = 'CANCELLED'
    THEN

        SELECT ac.*
        INTO v_cancellation

        FROM core.appointment_cancellations ac

        WHERE ac.business_id = p_business_id
          AND ac.appointment_id = p_appointment_id

        LIMIT 1;


        SELECT cs.*
        INTO v_calendar_sync

        FROM core.appointment_calendar_syncs cs

        WHERE cs.business_id = p_business_id
          AND cs.appointment_id = p_appointment_id
          AND cs.provider = 'GOOGLE'

        LIMIT 1;


        v_calendar_delete_required :=
            v_calendar_sync.id IS NOT NULL
            AND v_calendar_sync.external_event_id IS NOT NULL
            AND NOT (
                v_calendar_sync.last_operation = 'DELETE'
                AND v_calendar_sync.sync_status = 'SYNCED'
            );


        RETURN JSONB_BUILD_OBJECT(

            'ok',
                TRUE,

            'code',
                'APPOINTMENT_ALREADY_CANCELLED',

            'appointment_id',
                v_appointment.id,

            'status',
                v_appointment.status,

            'cancelled_at',
                v_appointment.cancelled_at,

            'cancellation',
                CASE
                    WHEN v_cancellation.id IS NULL
                        THEN NULL
                    ELSE JSONB_BUILD_OBJECT(

                        'cancellation_id',
                            v_cancellation.id,

                        'actor_type',
                            v_cancellation.actor_type,

                        'public_reason',
                            v_cancellation.public_reason,

                        'internal_reason',
                            v_cancellation.internal_reason,

                        'notification_status',
                            v_cancellation.customer_notification_status
                    )
                END,

            'calendar_sync',
                JSONB_BUILD_OBJECT(

                    'required',
                        v_calendar_delete_required,

                    'operation',
                        CASE
                            WHEN v_calendar_delete_required
                                THEN 'DELETE'
                            ELSE NULL
                        END,

                    'appointment_id',
                        v_appointment.id,

                    'external_calendar_id',
                        v_calendar_sync.external_calendar_id,

                    'external_event_id',
                        v_calendar_sync.external_event_id
                )
        );

    END IF;


    -- ========================================================
    -- SOMENTE CONFIRMED PODE SER CANCELADO NESTA VERSÃO
    -- ========================================================

    IF v_appointment.status <> 'CONFIRMED'
    THEN

        RETURN JSONB_BUILD_OBJECT(

            'ok',
                FALSE,

            'code',
                'APPOINTMENT_NOT_CANCELLABLE',

            'appointment_id',
                v_appointment.id,

            'status',
                v_appointment.status
        );

    END IF;


    -- ========================================================
    -- REGRAS DE CANCELAMENTO PELO CLIENTE
    -- ========================================================

    IF v_actor_type = 'CUSTOMER'
    THEN

        IF p_actor_customer_id IS NULL
           OR p_actor_customer_id <> v_appointment.customer_id
        THEN

            RETURN JSONB_BUILD_OBJECT(
                'ok', FALSE,
                'code', 'CUSTOMER_NOT_AUTHORIZED_FOR_APPOINTMENT'
            );

        END IF;


        SELECT bs.*
        INTO v_settings

        FROM core.business_settings bs

        WHERE bs.business_id = p_business_id

        LIMIT 1;


        IF NOT FOUND
        THEN

            RETURN JSONB_BUILD_OBJECT(
                'ok', FALSE,
                'code', 'BUSINESS_SETTINGS_NOT_FOUND'
            );

        END IF;


        IF v_settings.cancellation_enabled IS NOT TRUE
        THEN

            RETURN JSONB_BUILD_OBJECT(
                'ok', FALSE,
                'code', 'CUSTOMER_CANCELLATION_DISABLED'
            );

        END IF;


        v_cancellation_deadline :=
            v_appointment.start_at
            -
            MAKE_INTERVAL(
                mins =>
                    COALESCE(
                        v_settings.cancellation_notice_minutes,
                        0
                    )
            );


        IF NOW() > v_cancellation_deadline
        THEN

            RETURN JSONB_BUILD_OBJECT(

                'ok',
                    FALSE,

                'code',
                    'CANCELLATION_NOTICE_VIOLATION',

                'appointment_id',
                    v_appointment.id,

                'start_at',
                    v_appointment.start_at,

                'cancellation_deadline',
                    v_cancellation_deadline,

                'notice_minutes',
                    v_settings.cancellation_notice_minutes
            );

        END IF;

    END IF;


    -- ========================================================
    -- CANCELAMENTO PELO PROFISSIONAL
    -- ========================================================

    IF v_actor_type = 'PROFESSIONAL'
    THEN

        IF p_actor_professional_id IS NULL
           OR p_actor_professional_id <> v_appointment.professional_id
        THEN

            RETURN JSONB_BUILD_OBJECT(
                'ok', FALSE,
                'code', 'PROFESSIONAL_NOT_AUTHORIZED_FOR_APPOINTMENT'
            );

        END IF;


        IF v_public_reason IS NULL
        THEN

            RETURN JSONB_BUILD_OBJECT(
                'ok', FALSE,
                'code', 'PUBLIC_CANCELLATION_REASON_REQUIRED'
            );

        END IF;

    END IF;


    -- ========================================================
    -- CANCELAMENTO PELA EMPRESA
    -- ========================================================

    IF v_actor_type = 'BUSINESS'
       AND v_public_reason IS NULL
    THEN

        RETURN JSONB_BUILD_OBJECT(
            'ok', FALSE,
            'code', 'PUBLIC_CANCELLATION_REASON_REQUIRED'
        );

    END IF;


    -- ========================================================
    -- CANCELAR APPOINTMENT
    -- ========================================================

    UPDATE core.appointments

    SET
        status =
            'CANCELLED',

        cancelled_at =
            NOW(),

        cancellation_reason =
            v_public_reason,

        metadata =
            COALESCE(
                metadata,
                '{}'::JSONB
            )
            ||
            JSONB_BUILD_OBJECT(

                'cancellation',

                JSONB_BUILD_OBJECT(

                    'actor_type',
                        v_actor_type,

                    'actor_customer_id',
                        p_actor_customer_id,

                    'actor_professional_id',
                        p_actor_professional_id,

                    'actor_ref',
                        p_actor_ref,

                    'public_reason',
                        v_public_reason,

                    'source_channel',
                        p_source_channel,

                    'source_provider',
                        p_source_provider,

                    'cancelled_at',
                        NOW()
                )
            ),

        updated_at =
            NOW()

    WHERE business_id = p_business_id
      AND id = p_appointment_id

    RETURNING *
    INTO v_appointment;


    -- ========================================================
    -- AUDITORIA
    -- ========================================================

    INSERT INTO core.appointment_cancellations (

        business_id,
        appointment_id,

        customer_id,
        professional_id,

        actor_type,

        actor_customer_id,
        actor_professional_id,
        actor_ref,

        public_reason,
        internal_reason,

        source_channel,
        source_provider,

        customer_notification_required,
        customer_notification_status,

        cancelled_at,
        created_at,
        updated_at
    )

    VALUES (

        p_business_id,
        p_appointment_id,

        v_appointment.customer_id,
        v_appointment.professional_id,

        v_actor_type,

        p_actor_customer_id,
        p_actor_professional_id,
        p_actor_ref,

        v_public_reason,
        v_internal_reason,

        p_source_channel,
        p_source_provider,

        TRUE,
        'PENDING',

        v_appointment.cancelled_at,
        NOW(),
        NOW()
    )

    RETURNING *
    INTO v_cancellation;


    -- ========================================================
    -- VERIFICAR SE EXISTE EVENTO GOOGLE PARA DELETAR
    -- ========================================================

    SELECT cs.*
    INTO v_calendar_sync

    FROM core.appointment_calendar_syncs cs

    WHERE cs.business_id = p_business_id
      AND cs.appointment_id = p_appointment_id
      AND cs.provider = 'GOOGLE'

    LIMIT 1;


    v_calendar_delete_required :=
        v_calendar_sync.id IS NOT NULL
        AND v_calendar_sync.external_event_id IS NOT NULL;


    -- ========================================================
    -- RETORNO
    -- ========================================================

    RETURN JSONB_BUILD_OBJECT(

        'ok',
            TRUE,

        'code',
            'APPOINTMENT_CANCELLED',

        'result_type',
            'APPOINTMENT_CANCELLATION',

        'appointment',
            JSONB_BUILD_OBJECT(

                'appointment_id',
                    v_appointment.id,

                'status',
                    v_appointment.status,

                'customer_id',
                    v_appointment.customer_id,

                'professional_id',
                    v_appointment.professional_id,

                'start_at',
                    v_appointment.start_at,

                'end_at',
                    v_appointment.end_at,

                'cancelled_at',
                    v_appointment.cancelled_at,

                'cancellation_reason',
                    v_public_reason
            ),

        'cancellation',
            JSONB_BUILD_OBJECT(

                'cancellation_id',
                    v_cancellation.id,

                'actor_type',
                    v_cancellation.actor_type,

                'actor_customer_id',
                    v_cancellation.actor_customer_id,

                'actor_professional_id',
                    v_cancellation.actor_professional_id,

                'actor_ref',
                    v_cancellation.actor_ref,

                'public_reason',
                    v_cancellation.public_reason,

                'internal_reason',
                    v_cancellation.internal_reason
            ),

        'customer_notification',
            JSONB_BUILD_OBJECT(

                'required',
                    TRUE,

                'status',
                    'PENDING',

                'type',
                    'APPOINTMENT_CANCELLED',

                'customer_id',
                    v_appointment.customer_id,

                'appointment_id',
                    v_appointment.id,

                'professional_id',
                    v_appointment.professional_id,

                'start_at',
                    v_appointment.start_at,

                'end_at',
                    v_appointment.end_at,

                'public_reason',
                    v_public_reason,

                'cancelled_by',
                    v_actor_type,

                'offer_rebooking',
                    v_actor_type IN (
                        'PROFESSIONAL',
                        'BUSINESS'
                    )
            ),

        'calendar_sync',
            JSONB_BUILD_OBJECT(

                'required',
                    v_calendar_delete_required,

                'operation',
                    CASE
                        WHEN v_calendar_delete_required
                            THEN 'DELETE'
                        ELSE NULL
                    END,

                'appointment_id',
                    v_appointment.id,

                'sync_id',
                    v_calendar_sync.id,

                'external_calendar_id',
                    v_calendar_sync.external_calendar_id,

                'external_event_id',
                    v_calendar_sync.external_event_id
            ),

        'timezone',
            v_business.timezone
    );

END;
$$;



-- ============================================================
-- 3. ATUALIZAR STATUS DA NOTIFICAÇÃO
-- ============================================================

CREATE OR REPLACE FUNCTION
core.mark_appointment_cancellation_notification(
    p_business_id UUID,
    p_appointment_id UUID,
    p_status TEXT,
    p_message_id UUID DEFAULT NULL,
    p_error TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
VOLATILE
AS $$
DECLARE

    v_status TEXT;

    v_cancellation core.appointment_cancellations%ROWTYPE;

BEGIN

    v_status :=
        UPPER(
            BTRIM(
                COALESCE(
                    p_status,
                    ''
                )
            )
        );


    IF v_status NOT IN (
        'SENT',
        'FAILED'
    )
    THEN

        RETURN JSONB_BUILD_OBJECT(
            'ok', FALSE,
            'code', 'INVALID_NOTIFICATION_STATUS'
        );

    END IF;


    UPDATE core.appointment_cancellations

    SET
        customer_notification_status =
            v_status,

        customer_notification_message_id =
            CASE
                WHEN v_status = 'SENT'
                    THEN p_message_id
                ELSE customer_notification_message_id
            END,

        customer_notified_at =
            CASE
                WHEN v_status = 'SENT'
                    THEN NOW()
                ELSE customer_notified_at
            END,

        notification_error =
            CASE
                WHEN v_status = 'FAILED'
                    THEN p_error
                ELSE NULL
            END,

        updated_at =
            NOW()

    WHERE business_id = p_business_id
      AND appointment_id = p_appointment_id

    RETURNING *
    INTO v_cancellation;


    IF NOT FOUND
    THEN

        RETURN JSONB_BUILD_OBJECT(
            'ok', FALSE,
            'code', 'APPOINTMENT_CANCELLATION_NOT_FOUND'
        );

    END IF;


    RETURN JSONB_BUILD_OBJECT(

        'ok',
            TRUE,

        'code',
            'CANCELLATION_NOTIFICATION_UPDATED',

        'cancellation_id',
            v_cancellation.id,

        'appointment_id',
            v_cancellation.appointment_id,

        'notification_status',
            v_cancellation.customer_notification_status,

        'customer_notified_at',
            v_cancellation.customer_notified_at
    );

END;
$$;