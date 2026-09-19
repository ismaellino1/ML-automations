-- ============================================================
-- ML AUTOMAÇÕES
-- Migration: 016_integrate_availability_into_hold
--
-- Finalidade:
-- Integrar o motor real de disponibilidade à criação de HOLD.
--
-- A partir desta migration, create_appointment_hold():
--
-- 1. valida empresa
-- 2. valida cliente
-- 3. valida profissional
-- 4. valida serviços
-- 5. calcula preço/duração/buffers
-- 6. limpa HOLDs vencidos conflitantes
-- 7. consulta check_slot_availability()
-- 8. somente então tenta criar o HOLD
--
-- A exclusion constraint continua sendo a última linha
-- de defesa contra concorrência.
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

    v_block_start TIMESTAMPTZ;
    v_block_end TIMESTAMPTZ;

    v_appointment_id UUID;

    v_availability JSONB;

BEGIN


    -- ========================================================
    -- 1. VALIDAR EMPRESA
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
    -- 2. CARREGAR CONFIGURAÇÕES
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


    v_hold_minutes :=
        COALESCE(v_hold_minutes, 5);

    v_minimum_notice :=
        COALESCE(v_minimum_notice, 0);

    v_booking_horizon :=
        COALESCE(v_booking_horizon, 60);


    -- ========================================================
    -- 3. VALIDAR HORIZONTE TEMPORAL
    -- ========================================================

    IF p_start_at <
        NOW()
        + make_interval(
            mins => v_minimum_notice
        )
    THEN

        RETURN jsonb_build_object(
            'ok', FALSE,
            'code', 'BOOKING_TOO_SOON'
        );

    END IF;


    IF p_start_at >
        NOW()
        + make_interval(
            days => v_booking_horizon
        )
    THEN

        RETURN jsonb_build_object(
            'ok', FALSE,
            'code', 'BOOKING_TOO_FAR'
        );

    END IF;


    -- ========================================================
    -- 4. VALIDAR CLIENTE
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
    -- 5. VALIDAR PROFISSIONAL
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
    -- 6. VALIDAR SERVIÇOS
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
    -- 7. CALCULAR PERÍODO DO ATENDIMENTO
    -- ========================================================

    v_end_at :=
        p_start_at
        + make_interval(
            mins => v_total_minutes
        );


    v_block_start :=
        p_start_at
        - make_interval(
            mins => v_buffer_before
        );


    v_block_end :=
        v_end_at
        + make_interval(
            mins => v_buffer_after
        );


    v_hold_expires_at :=
        NOW()
        + make_interval(
            mins => v_hold_minutes
        );


    -- ========================================================
    -- 8. LIMPAR HOLDs VENCIDOS QUE PODERIAM BLOQUEAR
    --    ESTE MESMO PERÍODO
    --
    -- Importante:
    -- check_slot_availability ignora HOLD vencido logicamente,
    -- porém a exclusion constraint trabalha com STATUS.
    --
    -- Portanto transformamos HOLDs vencidos em EXPIRED
    -- antes de tentar reutilizar o horário.
    -- ========================================================

    WITH expired AS (

        UPDATE core.appointments a

        SET status = 'EXPIRED'

        WHERE a.business_id = p_business_id

          AND a.professional_id =
                p_professional_id

          AND a.status = 'HOLD'

          AND a.hold_expires_at <= NOW()

          AND a.blocked_period
                &&
              tstzrange(
                  v_block_start,
                  v_block_end,
                  '[)'
              )

        RETURNING
            a.id,
            a.business_id

    )

    INSERT INTO core.appointment_events (
        business_id,
        appointment_id,
        event_type,
        from_status,
        to_status,
        actor_type
    )

    SELECT
        business_id,
        id,
        'HOLD_EXPIRED',
        'HOLD',
        'EXPIRED',
        'SYSTEM'

    FROM expired;


    -- Expira também eventual oferta de waitlist
    -- associada a um HOLD já vencido.

    UPDATE core.waitlist_offers wo

    SET
        status = 'EXPIRED',
        responded_at = COALESCE(
            wo.responded_at,
            NOW()
        )

    WHERE wo.business_id =
            p_business_id

      AND wo.status IN (
            'PENDING',
            'SENT'
      )

      AND EXISTS (

          SELECT 1

          FROM core.appointments a

          WHERE a.business_id =
                    wo.business_id

            AND a.id =
                    wo.hold_appointment_id

            AND a.status =
                    'EXPIRED'
      );


    -- ========================================================
    -- 9. CONSULTAR MOTOR DE DISPONIBILIDADE
    -- ========================================================

    v_availability :=
        core.check_slot_availability(

            p_business_id,

            p_professional_id,

            p_start_at,

            v_end_at,

            v_buffer_before,

            v_buffer_after,

            NULL
        );


    IF COALESCE(
        (v_availability ->> 'available')::BOOLEAN,
        FALSE
    ) = FALSE
    THEN

        RETURN jsonb_build_object(

            'ok', FALSE,

            'code',
                COALESCE(
                    v_availability ->> 'code',
                    'SLOT_NOT_AVAILABLE'
                ),

            'availability',
                v_availability
        );

    END IF;


    -- ========================================================
    -- 10. CRIAR HOLD
    --
    -- Mesmo depois do check, outra transação pode tentar
    -- pegar o mesmo horário.
    --
    -- A exclusion constraint continua sendo a garantia final.
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
    -- 11. SNAPSHOT DOS SERVIÇOS
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
       AND ps.professional_id =
            p_professional_id
       AND ps.service_id = s.id;


    -- ========================================================
    -- 12. EVENTO
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
                v_hold_expires_at,

            'availability_check',
                v_availability
        )
    );


    -- ========================================================
    -- 13. RESPOSTA
    -- ========================================================

    RETURN jsonb_build_object(

        'ok', TRUE,

        'code',
            'HOLD_CREATED',

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

        'currency',
            'BRL',

        'total_service_minutes',
            v_total_minutes,

        'buffer_before_minutes',
            v_buffer_before,

        'buffer_after_minutes',
            v_buffer_after

    );

END;

$$;