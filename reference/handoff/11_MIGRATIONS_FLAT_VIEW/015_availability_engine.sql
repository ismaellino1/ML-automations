-- ============================================================
-- ML AUTOMAÇÕES
-- Migration: 015_availability_engine
--
-- Finalidade:
-- Criar o validador central de disponibilidade.
--
-- Verifica:
-- - empresa ativa
-- - profissional ativo
-- - slot alinhado
-- - horário de funcionamento
-- - escala do profissional
-- - OPEN overrides
-- - CLOSED overrides
-- - agendamentos/HOLDs existentes
-- - buffers
--
-- Esta função ainda NÃO cria agendamento.
-- Apenas responde se aquele período pode ser usado.
-- ============================================================


CREATE OR REPLACE FUNCTION core.check_slot_availability(

    p_business_id UUID,

    p_professional_id UUID,

    p_start_at TIMESTAMPTZ,

    p_end_at TIMESTAMPTZ,

    p_buffer_before_minutes INTEGER DEFAULT 0,

    p_buffer_after_minutes INTEGER DEFAULT 0,

    -- Útil futuramente para remarcação.
    -- Permite ignorar o próprio agendamento.
    p_ignore_appointment_id UUID DEFAULT NULL

)
RETURNS JSONB

LANGUAGE plpgsql

AS $$

DECLARE

    v_timezone TEXT;

    v_slot_interval INTEGER;

    v_block_start TIMESTAMPTZ;
    v_block_end TIMESTAMPTZ;

    v_local_start TIMESTAMP;
    v_local_end TIMESTAMP;

    v_service_local_start TIMESTAMP;

    v_local_date DATE;

    v_weekday SMALLINT;

    v_start_minute INTEGER;

    v_business_regular BOOLEAN;

    v_professional_regular BOOLEAN;

    v_business_open_override BOOLEAN;

    v_professional_open_override BOOLEAN;

    v_closed_override BOOLEAN;

    v_conflict UUID;

BEGIN


    -- ========================================================
    -- 1. VALIDAÇÕES BÁSICAS
    -- ========================================================

    IF p_start_at IS NULL
       OR p_end_at IS NULL
       OR p_end_at <= p_start_at
    THEN

        RETURN jsonb_build_object(
            'available', FALSE,
            'code', 'INVALID_TIME_RANGE'
        );

    END IF;


    IF COALESCE(p_buffer_before_minutes, 0) < 0
       OR COALESCE(p_buffer_after_minutes, 0) < 0
    THEN

        RETURN jsonb_build_object(
            'available', FALSE,
            'code', 'INVALID_BUFFER'
        );

    END IF;


    -- ========================================================
    -- 2. EMPRESA + TIMEZONE
    -- ========================================================

    SELECT timezone

    INTO v_timezone

    FROM core.businesses

    WHERE id = p_business_id
      AND status = 'ACTIVE';


    IF NOT FOUND THEN

        RETURN jsonb_build_object(
            'available', FALSE,
            'code', 'BUSINESS_NOT_AVAILABLE'
        );

    END IF;


    -- ========================================================
    -- 3. PROFISSIONAL
    -- ========================================================

    IF NOT EXISTS (

        SELECT 1

        FROM core.professionals

        WHERE business_id = p_business_id
          AND id = p_professional_id
          AND active = TRUE
          AND online_booking_enabled = TRUE

    )
    THEN

        RETURN jsonb_build_object(
            'available', FALSE,
            'code', 'PROFESSIONAL_NOT_AVAILABLE'
        );

    END IF;


    -- ========================================================
    -- 4. CONFIGURAÇÃO DO INTERVALO DE SLOTS
    -- ========================================================

    SELECT slot_interval_minutes

    INTO v_slot_interval

    FROM core.business_settings

    WHERE business_id = p_business_id;


    v_slot_interval :=
        COALESCE(
            v_slot_interval,
            15
        );


    -- ========================================================
    -- 5. PERÍODO REAL BLOQUEADO
    --
    -- Exemplo:
    --
    -- serviço 10:00–10:30
    -- buffer antes = 5
    -- buffer depois = 10
    --
    -- agenda bloqueada:
    -- 09:55–10:40
    -- ========================================================

    v_block_start :=
        p_start_at
        - make_interval(
            mins => COALESCE(
                p_buffer_before_minutes,
                0
            )
        );


    v_block_end :=
        p_end_at
        + make_interval(
            mins => COALESCE(
                p_buffer_after_minutes,
                0
            )
        );


    -- ========================================================
    -- 6. CONVERTER PARA HORÁRIO LOCAL DA EMPRESA
    -- ========================================================

    v_local_start :=
        v_block_start
        AT TIME ZONE v_timezone;


    v_local_end :=
        v_block_end
        AT TIME ZONE v_timezone;


    v_service_local_start :=
        p_start_at
        AT TIME ZONE v_timezone;


    -- ========================================================
    -- 7. POR ENQUANTO NÃO ACEITAMOS SLOT CRUZANDO MEIA-NOITE
    -- ========================================================

    IF v_local_start::DATE
       <> v_local_end::DATE
    THEN

        RETURN jsonb_build_object(
            'available', FALSE,
            'code', 'CROSS_DAY_SLOT_NOT_SUPPORTED'
        );

    END IF;


    v_local_date :=
        v_local_start::DATE;


    v_weekday :=
        EXTRACT(
            ISODOW
            FROM v_local_start
        )::SMALLINT;


    -- ========================================================
    -- 8. ALINHAMENTO DO SLOT
    --
    -- BARB001 está configurada para 15 min.
    --
    -- Válidos:
    -- 10:00
    -- 10:15
    -- 10:30
    --
    -- Inválido:
    -- 10:07
    -- ========================================================

    v_start_minute :=
        (
            EXTRACT(
                HOUR
                FROM v_service_local_start
            )::INTEGER
            * 60
        )
        +
        EXTRACT(
            MINUTE
            FROM v_service_local_start
        )::INTEGER;


    IF MOD(
        v_start_minute,
        v_slot_interval
    ) <> 0

       OR EXTRACT(
            SECOND
            FROM v_service_local_start
       ) <> 0
    THEN

        RETURN jsonb_build_object(
            'available', FALSE,
            'code', 'SLOT_NOT_ALIGNED',
            'slot_interval_minutes',
            v_slot_interval
        );

    END IF;


    -- ========================================================
    -- 9. CLOSED OVERRIDE
    --
    -- CLOSED tem prioridade.
    --
    -- Pode ser:
    -- - estabelecimento inteiro
    -- - profissional específico
    -- ========================================================

    SELECT EXISTS (

        SELECT 1

        FROM core.availability_overrides ao

        WHERE ao.business_id = p_business_id

          AND ao.active = TRUE

          AND ao.override_type = 'CLOSED'

          AND (
                ao.professional_id IS NULL
                OR
                ao.professional_id =
                    p_professional_id
          )

          AND ao.start_at < v_block_end

          AND ao.end_at > v_block_start

    )

    INTO v_closed_override;


    IF v_closed_override THEN

        RETURN jsonb_build_object(
            'available', FALSE,
            'code', 'CLOSED_OVERRIDE'
        );

    END IF;


    -- ========================================================
    -- 10. HORÁRIO NORMAL DO ESTABELECIMENTO
    -- ========================================================

    SELECT EXISTS (

        SELECT 1

        FROM core.business_hours bh

        WHERE bh.business_id =
                p_business_id

          AND bh.active = TRUE

          AND bh.weekday =
                v_weekday

          AND (
                bh.valid_from IS NULL
                OR
                bh.valid_from <= v_local_date
          )

          AND (
                bh.valid_until IS NULL
                OR
                bh.valid_until >= v_local_date
          )

          AND bh.start_time
                <= v_local_start::TIME

          AND bh.end_time
                >= v_local_end::TIME

    )

    INTO v_business_regular;


    -- ========================================================
    -- 11. OPEN EXTRAORDINÁRIO DO ESTABELECIMENTO
    -- ========================================================

    SELECT EXISTS (

        SELECT 1

        FROM core.availability_overrides ao

        WHERE ao.business_id =
                p_business_id

          AND ao.professional_id IS NULL

          AND ao.override_type = 'OPEN'

          AND ao.active = TRUE

          AND ao.start_at <= v_block_start

          AND ao.end_at >= v_block_end

    )

    INTO v_business_open_override;


    IF NOT v_business_regular
       AND NOT v_business_open_override
    THEN

        RETURN jsonb_build_object(
            'available', FALSE,
            'code', 'OUTSIDE_BUSINESS_HOURS'
        );

    END IF;


    -- ========================================================
    -- 12. ESCALA NORMAL DO PROFISSIONAL
    -- ========================================================

    SELECT EXISTS (

        SELECT 1

        FROM core.professional_hours ph

        WHERE ph.business_id =
                p_business_id

          AND ph.professional_id =
                p_professional_id

          AND ph.active = TRUE

          AND ph.weekday =
                v_weekday

          AND (
                ph.valid_from IS NULL
                OR
                ph.valid_from <= v_local_date
          )

          AND (
                ph.valid_until IS NULL
                OR
                ph.valid_until >= v_local_date
          )

          AND ph.start_time
                <= v_local_start::TIME

          AND ph.end_time
                >= v_local_end::TIME

    )

    INTO v_professional_regular;


    -- ========================================================
    -- 13. OPEN EXTRAORDINÁRIO DO PROFISSIONAL
    -- ========================================================

    SELECT EXISTS (

        SELECT 1

        FROM core.availability_overrides ao

        WHERE ao.business_id =
                p_business_id

          AND ao.professional_id =
                p_professional_id

          AND ao.override_type = 'OPEN'

          AND ao.active = TRUE

          AND ao.start_at <= v_block_start

          AND ao.end_at >= v_block_end

    )

    INTO v_professional_open_override;


    IF NOT v_professional_regular
       AND NOT v_professional_open_override
    THEN

        RETURN jsonb_build_object(
            'available', FALSE,
            'code', 'OUTSIDE_PROFESSIONAL_HOURS'
        );

    END IF;


    -- ========================================================
    -- 14. AGENDAMENTOS EXISTENTES
    --
    -- HOLD vencido não conta nesta pré-verificação.
    --
    -- A exclusion constraint continua sendo a proteção
    -- definitiva contra condições de corrida.
    -- ========================================================

    SELECT a.id

    INTO v_conflict

    FROM core.appointments a

    WHERE a.business_id =
            p_business_id

      AND a.professional_id =
            p_professional_id

      AND a.status IN (
            'HOLD',
            'CONFIRMED',
            'CHECKED_IN'
      )

      AND (
            a.status <> 'HOLD'
            OR
            a.hold_expires_at > NOW()
      )

      AND (
            p_ignore_appointment_id IS NULL
            OR
            a.id <> p_ignore_appointment_id
      )

      AND a.blocked_period
            &&
          tstzrange(
              v_block_start,
              v_block_end,
              '[)'
          )

    LIMIT 1;


    IF FOUND THEN

        RETURN jsonb_build_object(
            'available', FALSE,
            'code', 'SLOT_UNAVAILABLE',
            'conflicting_appointment_id',
            v_conflict
        );

    END IF;


    -- ========================================================
    -- 15. DISPONÍVEL
    -- ========================================================

    RETURN jsonb_build_object(

        'available', TRUE,

        'code', 'AVAILABLE',

        'business_id',
            p_business_id,

        'professional_id',
            p_professional_id,

        'start_at',
            p_start_at,

        'end_at',
            p_end_at,

        'blocked_start_at',
            v_block_start,

        'blocked_end_at',
            v_block_end,

        'timezone',
            v_timezone,

        'weekday',
            v_weekday

    );

END;

$$;