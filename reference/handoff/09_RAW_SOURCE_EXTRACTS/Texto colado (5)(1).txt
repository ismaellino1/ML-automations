-- ============================================================
-- ML AUTOMAÇÕES
-- Migration: 013_appointment_transaction_functions
--
-- Finalidade:
-- Encapsular operações críticas de agenda em transações
-- executadas dentro do PostgreSQL.
--
-- O n8n não precisará fazer vários INSERT/UPDATE separados.
-- ============================================================


-- ============================================================
-- 1. CRIAR HOLD DE AGENDAMENTO
-- ============================================================

CREATE OR REPLACE FUNCTION core.create_appointment_hold(
    p_business_id UUID,
    p_customer_id UUID,
    p_professional_id UUID,
    p_start_at TIMESTAMPTZ,
    p_service_ids UUID[],
    p_source_channel VARCHAR DEFAULT NULL,
    p_source_provider VARCHAR DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
    v_business_status VARCHAR(30);

    v_customer_status VARCHAR(30);

    v_professional_active BOOLEAN;
    v_professional_booking_enabled BOOLEAN;

    v_requested_count INTEGER;
    v_valid_count INTEGER;

    v_total_minutes INTEGER;
    v_total_price NUMERIC(10,2);

    v_buffer_before INTEGER;
    v_buffer_after INTEGER;

    v_hold_minutes INTEGER;
    v_minimum_notice INTEGER;
    v_booking_horizon INTEGER;

    v_end_at TIMESTAMPTZ;
    v_hold_expires_at TIMESTAMPTZ;

    v_appointment_id UUID;
BEGIN

    -- ========================================================
    -- 1.1 VALIDAR EMPRESA
    -- ========================================================

    SELECT status
    INTO v_business_status

    FROM core.businesses

    WHERE id = p_business_id;


    IF NOT FOUND THEN

        RETURN jsonb_build_object(
            'ok', FALSE,
            'code', 'BUSINESS_NOT_FOUND'
        );

    END IF;


    IF v_business_status <> 'ACTIVE' THEN

        RETURN jsonb_build_object(
            'ok', FALSE,
            'code', 'BUSINESS_NOT_ACTIVE'
        );

    END IF;


    -- ========================================================
    -- 1.2 CONFIGURAÇÕES
    -- ========================================================

    SELECT
        hold_duration_minutes,
        minimum_booking_notice_minutes,
        maximum_booking_horizon_days

    INTO
        v_hold_minutes,
        v_minimum_notice,
        v_booking_horizon

    FROM core.business_settings

    WHERE business_id = p_business_id;


    -- Fallback defensivo caso configuração não exista.
    v_hold_minutes :=
        COALESCE(v_hold_minutes, 5);

    v_minimum_notice :=
        COALESCE(v_minimum_notice, 0);

    v_booking_horizon :=
        COALESCE(v_booking_horizon, 60);


    -- ========================================================
    -- 1.3 VALIDAR DATA
    -- ========================================================

    IF p_start_at <
        NOW() + make_interval(
            mins => v_minimum_notice
        )
    THEN

        RETURN jsonb_build_object(
            'ok', FALSE,
            'code', 'BOOKING_TOO_SOON'
        );

    END IF;


    IF p_start_at >
        NOW() + make_interval(
            days => v_booking_horizon
        )
    THEN

        RETURN jsonb_build_object(
            'ok', FALSE,
            'code', 'BOOKING_TOO_FAR'
        );

    END IF;


    -- ========================================================
    -- 1.4 VALIDAR CLIENTE
    -- ========================================================

    SELECT status
    INTO v_customer_status

    FROM core.customers

    WHERE business_id = p_business_id
      AND id = p_customer_id;


    IF NOT FOUND THEN

        RETURN jsonb_build_object(
            'ok', FALSE,
            'code', 'CUSTOMER_NOT_FOUND'
        );

    END IF;


    IF v_customer_status <> 'ACTIVE' THEN

        RETURN jsonb_build_object(
            'ok', FALSE,
            'code', 'CUSTOMER_NOT_ACTIVE'
        );

    END IF;


    -- ========================================================
    -- 1.5 VALIDAR PROFISSIONAL
    -- ========================================================

    SELECT
        active,
        online_booking_enabled

    INTO
        v_professional_active,
        v_professional_booking_enabled

    FROM core.professionals

    WHERE business_id = p_business_id
      AND id = p_professional_id;


    IF NOT FOUND THEN

        RETURN jsonb_build_object(
            'ok', FALSE,
            'code', 'PROFESSIONAL_NOT_FOUND'
        );

    END IF;


    IF NOT v_professional_active
       OR NOT v_professional_booking_enabled
    THEN

        RETURN jsonb_build_object(
            'ok', FALSE,
            'code', 'PROFESSIONAL_NOT_AVAILABLE'
        );

    END IF;


    -- ========================================================
    -- 1.6 VALIDAR SERVIÇOS
    -- ========================================================

    v_requested_count :=
        COALESCE(
            cardinality(p_service_ids),
            0
        );


    IF v_requested_count = 0 THEN

        RETURN jsonb_build_object(
            'ok', FALSE,
            'code', 'NO_SERVICES_SELECTED'
        );

    END IF;


    SELECT
        COUNT(*)::INTEGER,

        COALESCE(
            SUM(
                COALESCE(
                    ps.duration_minutes_override,
                    s.duration_minutes
                )
            ),
            0
        )::INTEGER,

        COALESCE(
            SUM(
                COALESCE(
                    ps.price_override,
                    s.price
                )
            ),
            0
        )::NUMERIC(10,2),

        COALESCE(
            MAX(s.buffer_before_minutes),
            0
        ),

        COALESCE(
            MAX(s.buffer_after_minutes),
            0
        )

    INTO
        v_valid_count,
        v_total_minutes,
        v_total_price,
        v_buffer_before,
        v_buffer_after

    FROM unnest(p_service_ids)
        WITH ORDINALITY
        AS requested(service_id, ord)

    JOIN core.services s
        ON s.id = requested.service_id
       AND s.business_id = p_business_id
       AND s.active = TRUE
       AND s.online_booking_enabled = TRUE

    JOIN core.professional_services ps
        ON ps.business_id = p_business_id
       AND ps.professional_id = p_professional_id
       AND ps.service_id = s.id
       AND ps.active = TRUE
       AND ps.online_booking_enabled = TRUE;


    IF v_valid_count <> v_requested_count THEN

        RETURN jsonb_build_object(
            'ok', FALSE,
            'code', 'INVALID_OR_UNAVAILABLE_SERVICE'
        );

    END IF;


    -- ========================================================
    -- 1.7 CALCULAR HORÁRIOS
    -- ========================================================

    v_end_at :=
        p_start_at
        + make_interval(
            mins => v_total_minutes
        );


    v_hold_expires_at :=
        NOW()
        + make_interval(
            mins => v_hold_minutes
        );


    -- ========================================================
    -- 1.8 CRIAR AGENDAMENTO HOLD
    --
    -- A exclusion constraint do banco é quem dá a palavra final
    -- sobre conflito de horário.
    -- ========================================================

    BEGIN

        INSERT INTO core.appointments (
            business_id,
            customer_id,
            professional_id,

            status,

            start_at,
            end_at,

            buffer_before_minutes,
            buffer_after_minutes,

            total_price,
            currency,
            total_service_minutes,

            hold_expires_at,

            source_channel,
            source_provider
        )

        VALUES (
            p_business_id,
            p_customer_id,
            p_professional_id,

            'HOLD',

            p_start_at,
            v_end_at,

            v_buffer_before,
            v_buffer_after,

            v_total_price,
            'BRL',
            v_total_minutes,

            v_hold_expires_at,

            p_source_channel,
            p_source_provider
        )

        RETURNING id
        INTO v_appointment_id;


    EXCEPTION

        WHEN exclusion_violation THEN

            RETURN jsonb_build_object(
                'ok', FALSE,
                'code', 'SLOT_UNAVAILABLE'
            );

    END;


    -- ========================================================
    -- 1.9 SNAPSHOT DOS SERVIÇOS
    -- ========================================================

    INSERT INTO core.appointment_items (
        business_id,
        appointment_id,
        service_id,

        service_name_snapshot,
        price_snapshot,
        duration_minutes_snapshot,

        quantity,
        display_order
    )

    SELECT
        p_business_id,
        v_appointment_id,
        s.id,

        s.name,

        COALESCE(
            ps.price_override,
            s.price
        ),

        COALESCE(
            ps.duration_minutes_override,
            s.duration_minutes
        ),

        1,

        requested.ord::INTEGER

    FROM unnest(p_service_ids)
        WITH ORDINALITY
        AS requested(service_id, ord)

    JOIN core.services s
        ON s.id = requested.service_id
       AND s.business_id = p_business_id

    JOIN core.professional_services ps
        ON ps.business_id = p_business_id
       AND ps.professional_id = p_professional_id
       AND ps.service_id = s.id;


    -- ========================================================
    -- 1.10 AUDITORIA
    -- ========================================================

    INSERT INTO core.appointment_events (
        business_id,
        appointment_id,

        event_type,

        from_status,
        to_status,

        actor_type,

        payload
    )

    VALUES (
        p_business_id,
        v_appointment_id,

        'HOLD_CREATED',

        NULL,
        'HOLD',

        'AUTOMATION',

        jsonb_build_object(
            'hold_expires_at',
            v_hold_expires_at
        )
    );


    -- ========================================================
    -- 1.11 RESULTADO
    -- ========================================================

    RETURN jsonb_build_object(
        'ok', TRUE,

        'code', 'HOLD_CREATED',

        'appointment_id',
            v_appointment_id,

        'start_at',
            p_start_at,

        'end_at',
            v_end_at,

        'hold_expires_at',
            v_hold_expires_at,

        'total_price',
            v_total_price,

        'total_service_minutes',
            v_total_minutes,

        'buffer_before_minutes',
            v_buffer_before,

        'buffer_after_minutes',
            v_buffer_after
    );

END;
$$;


-- ============================================================
-- 2. CONFIRMAR UM HOLD
-- ============================================================

CREATE OR REPLACE FUNCTION core.confirm_appointment_hold(
    p_business_id UUID,
    p_appointment_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
    v_appointment core.appointments%ROWTYPE;
BEGIN

    -- Bloqueia a linha durante a operação.
    SELECT *
    INTO v_appointment

    FROM core.appointments

    WHERE business_id = p_business_id
      AND id = p_appointment_id

    FOR UPDATE;


    IF NOT FOUND THEN

        RETURN jsonb_build_object(
            'ok', FALSE,
            'code', 'APPOINTMENT_NOT_FOUND'
        );

    END IF;


    IF v_appointment.status <> 'HOLD' THEN

        RETURN jsonb_build_object(
            'ok', FALSE,
            'code', 'APPOINTMENT_NOT_HOLD',
            'current_status',
            v_appointment.status
        );

    END IF;


    -- ========================================================
    -- HOLD JÁ EXPIROU
    -- ========================================================

    IF v_appointment.hold_expires_at <= NOW() THEN

        UPDATE core.appointments

        SET status = 'EXPIRED'

        WHERE business_id = p_business_id
          AND id = p_appointment_id;


        INSERT INTO core.appointment_events (
            business_id,
            appointment_id,

            event_type,

            from_status,
            to_status,

            actor_type
        )

        VALUES (
            p_business_id,
            p_appointment_id,

            'HOLD_EXPIRED',

            'HOLD',
            'EXPIRED',

            'SYSTEM'
        );


        RETURN jsonb_build_object(
            'ok', FALSE,
            'code', 'HOLD_EXPIRED',
            'appointment_id',
            p_appointment_id
        );

    END IF;


    -- ========================================================
    -- CONFIRMAR
    -- ========================================================

    UPDATE core.appointments

    SET
        status = 'CONFIRMED',
        confirmed_at = NOW()

    WHERE business_id = p_business_id
      AND id = p_appointment_id;


    INSERT INTO core.appointment_events (
        business_id,
        appointment_id,

        event_type,

        from_status,
        to_status,

        actor_type
    )

    VALUES (
        p_business_id,
        p_appointment_id,

        'CONFIRMED',

        'HOLD',
        'CONFIRMED',

        'AUTOMATION'
    );


    RETURN jsonb_build_object(
        'ok', TRUE,
        'code', 'APPOINTMENT_CONFIRMED',
        'appointment_id',
        p_appointment_id
    );

END;
$$;


-- ============================================================
-- 3. EXPIRAR HOLDS VENCIDOS
-- ============================================================
--
-- Essa função será chamada futuramente por um workflow
-- agendado no n8n.
--
-- FOR UPDATE SKIP LOCKED permite vários workers sem
-- processarem o mesmo HOLD simultaneamente.
-- ============================================================

CREATE OR REPLACE FUNCTION core.expire_stale_holds(
    p_limit INTEGER DEFAULT 500
)
RETURNS INTEGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_record RECORD;
    v_count INTEGER := 0;
BEGIN

    IF p_limit IS NULL
       OR p_limit < 1
    THEN
        p_limit := 500;
    END IF;


    FOR v_record IN

        SELECT
            id,
            business_id

        FROM core.appointments

        WHERE status = 'HOLD'
          AND hold_expires_at <= NOW()

        ORDER BY hold_expires_at

        FOR UPDATE SKIP LOCKED

        LIMIT p_limit

    LOOP

        UPDATE core.appointments

        SET status = 'EXPIRED'

        WHERE business_id = v_record.business_id
          AND id = v_record.id
          AND status = 'HOLD';


        IF FOUND THEN

            INSERT INTO core.appointment_events (
                business_id,
                appointment_id,

                event_type,

                from_status,
                to_status,

                actor_type
            )

            VALUES (
                v_record.business_id,
                v_record.id,

                'HOLD_EXPIRED',

                'HOLD',
                'EXPIRED',

                'SYSTEM'
            );


            -- Se esse HOLD pertencia a uma oferta de waitlist,
            -- a oferta também expira.
            UPDATE core.waitlist_offers

            SET
                status = 'EXPIRED',
                responded_at = NOW()

            WHERE business_id =
                    v_record.business_id

              AND hold_appointment_id =
                    v_record.id

              AND status IN (
                    'PENDING',
                    'SENT'
              );


            v_count :=
                v_count + 1;

        END IF;

    END LOOP;


    RETURN v_count;

END;
$$;