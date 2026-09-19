-- ============================================================
-- ML AUTOMAÇÕES
-- Migration: 042_active_appointment_rescheduling
--
-- Finalidade:
-- 1. Preparar remarcação de appointment ativo sem liberar o horário original.
-- 2. Persistir a origem da remarcação na slot_offer.
-- 3. Na seleção, trocar appointment antigo -> RESCHEDULED e novo -> CONFIRMED
--    dentro da mesma transação.
-- 4. Preservar o appointment original se a troca falhar ou for abandonada.
-- 5. Manter REBOOK_APPOINTMENT separado de RESCHEDULE_APPOINTMENT.
-- 6. Expor instrução de Calendar separada; o espelho externo será orquestrado
--    em etapa própria depois do commit do Core.
-- ============================================================


-- ============================================================
-- 1. PREPARAR REMARCAÇÃO DE APPOINTMENT ATIVO
-- ============================================================

CREATE OR REPLACE FUNCTION core.prepare_appointment_reschedule(
    p_business_id UUID,
    p_conversation_id UUID,
    p_customer_id UUID,
    p_appointment_id UUID,
    p_requested_professional_id UUID DEFAULT NULL,
    p_requested_date DATE DEFAULT NULL,
    p_time_from TIME DEFAULT NULL,
    p_time_until TIME DEFAULT NULL,
    p_allow_professional_fallback BOOLEAN DEFAULT FALSE
)
RETURNS JSONB
LANGUAGE plpgsql
AS $function$
DECLARE
    v_appointment core.appointments%ROWTYPE;

    v_business_status TEXT;
    v_timezone TEXT := 'UTC';
    v_rescheduling_enabled BOOLEAN := TRUE;
    v_rescheduling_notice_minutes INTEGER := 60;
    v_slot_limit INTEGER := 5;
    v_offer_ttl INTEGER := 10;
    v_booking_horizon INTEGER := 60;

    v_service_ids UUID[];
    v_service_names TEXT;

    v_original_professional_id UUID;
    v_target_professional_id UUID;
    v_target_professional_name TEXT;

    v_today DATE;
    v_original_date DATE;
    v_date_from DATE;
    v_date_until DATE;
    v_max_date DATE;

    v_result JSONB := '{}'::JSONB;
    v_call_ok BOOLEAN := FALSE;
    v_has_slots BOOLEAN := FALSE;
    v_slot_offer_id UUID;
    v_search_scope TEXT := NULL;
BEGIN
    -- --------------------------------------------------------
    -- Contexto tenant/customer + serialização da conversa.
    -- --------------------------------------------------------
    PERFORM 1
    FROM core.conversations c
    WHERE c.id = p_conversation_id
      AND c.business_id = p_business_id
      AND c.customer_id = p_customer_id
      AND c.status = 'OPEN'
    FOR UPDATE;

    IF NOT FOUND THEN
        RETURN JSONB_BUILD_OBJECT(
            'ok', FALSE,
            'code', 'INVALID_CONVERSATION_CONTEXT',
            'action', 'RESCHEDULE_APPOINTMENT',
            'result_type', 'RESCHEDULING_ERROR',
            'calendar_sync', JSONB_BUILD_OBJECT(
                'required', FALSE,
                'operation', NULL
            )
        );
    END IF;

    -- --------------------------------------------------------
    -- Empresa + regras de remarcação.
    -- --------------------------------------------------------
    SELECT
        b.status,
        COALESCE(b.timezone, 'UTC'),
        COALESCE(bs.rescheduling_enabled, TRUE),
        COALESCE(bs.rescheduling_notice_minutes, 60),
        COALESCE(bs.max_slots_per_offer, 5),
        COALESCE(bs.waitlist_offer_ttl_minutes, 10),
        COALESCE(bs.maximum_booking_horizon_days, 60)
    INTO
        v_business_status,
        v_timezone,
        v_rescheduling_enabled,
        v_rescheduling_notice_minutes,
        v_slot_limit,
        v_offer_ttl,
        v_booking_horizon
    FROM core.businesses b
    LEFT JOIN core.business_settings bs
      ON bs.business_id = b.id
    WHERE b.id = p_business_id
    LIMIT 1;

    IF NOT FOUND THEN
        RETURN JSONB_BUILD_OBJECT(
            'ok', FALSE,
            'code', 'BUSINESS_NOT_FOUND',
            'action', 'RESCHEDULE_APPOINTMENT',
            'result_type', 'RESCHEDULING_ERROR',
            'calendar_sync', JSONB_BUILD_OBJECT('required', FALSE, 'operation', NULL)
        );
    END IF;

    IF v_business_status <> 'ACTIVE' THEN
        RETURN JSONB_BUILD_OBJECT(
            'ok', FALSE,
            'code', 'BUSINESS_NOT_ACTIVE',
            'action', 'RESCHEDULE_APPOINTMENT',
            'result_type', 'RESCHEDULING_ERROR',
            'calendar_sync', JSONB_BUILD_OBJECT('required', FALSE, 'operation', NULL)
        );
    END IF;

    IF v_rescheduling_enabled IS NOT TRUE THEN
        RETURN JSONB_BUILD_OBJECT(
            'ok', FALSE,
            'code', 'RESCHEDULING_DISABLED',
            'action', 'RESCHEDULE_APPOINTMENT',
            'result_type', 'RESCHEDULING_ERROR',
            'calendar_sync', JSONB_BUILD_OBJECT('required', FALSE, 'operation', NULL)
        );
    END IF;

    IF p_time_from IS NOT NULL
       AND p_time_until IS NOT NULL
       AND p_time_from >= p_time_until
    THEN
        RETURN JSONB_BUILD_OBJECT(
            'ok', FALSE,
            'code', 'INVALID_TIME_WINDOW',
            'action', 'RESCHEDULE_APPOINTMENT',
            'result_type', 'RESCHEDULING_ERROR',
            'calendar_sync', JSONB_BUILD_OBJECT('required', FALSE, 'operation', NULL)
        );
    END IF;

    -- --------------------------------------------------------
    -- Appointment de origem permanece CONFIRMED nesta etapa.
    -- --------------------------------------------------------
    SELECT a.*
    INTO v_appointment
    FROM core.appointments a
    WHERE a.id = p_appointment_id
      AND a.business_id = p_business_id
      AND a.customer_id = p_customer_id
    LIMIT 1
    FOR UPDATE;

    IF NOT FOUND THEN
        RETURN JSONB_BUILD_OBJECT(
            'ok', FALSE,
            'code', 'APPOINTMENT_NOT_FOUND_OR_NOT_OWNED',
            'action', 'RESCHEDULE_APPOINTMENT',
            'result_type', 'RESCHEDULING_ERROR',
            'calendar_sync', JSONB_BUILD_OBJECT('required', FALSE, 'operation', NULL)
        );
    END IF;

    IF v_appointment.status <> 'CONFIRMED' THEN
        RETURN JSONB_BUILD_OBJECT(
            'ok', FALSE,
            'code', 'APPOINTMENT_NOT_RESCHEDULABLE',
            'action', 'RESCHEDULE_APPOINTMENT',
            'result_type', 'RESCHEDULING_ERROR',
            'appointment_id', v_appointment.id,
            'appointment_status', v_appointment.status,
            'calendar_sync', JSONB_BUILD_OBJECT('required', FALSE, 'operation', NULL)
        );
    END IF;

    IF NOW() >
        v_appointment.start_at
        - MAKE_INTERVAL(mins => GREATEST(v_rescheduling_notice_minutes, 0))
    THEN
        RETURN JSONB_BUILD_OBJECT(
            'ok', FALSE,
            'code', 'RESCHEDULING_NOTICE_VIOLATION',
            'action', 'RESCHEDULE_APPOINTMENT',
            'result_type', 'RESCHEDULING_ERROR',
            'appointment_id', v_appointment.id,
            'start_at', v_appointment.start_at,
            'notice_minutes', v_rescheduling_notice_minutes,
            'calendar_sync', JSONB_BUILD_OBJECT('required', FALSE, 'operation', NULL)
        );
    END IF;

    -- --------------------------------------------------------
    -- Serviços: o vínculo vem do appointment existente.
    -- --------------------------------------------------------
    SELECT
        ARRAY_AGG(ai.service_id ORDER BY ai.display_order),
        STRING_AGG(ai.service_name_snapshot, ' + ' ORDER BY ai.display_order)
    INTO
        v_service_ids,
        v_service_names
    FROM core.appointment_items ai
    WHERE ai.business_id = p_business_id
      AND ai.appointment_id = p_appointment_id;

    IF v_service_ids IS NULL OR CARDINALITY(v_service_ids) = 0 THEN
        RETURN JSONB_BUILD_OBJECT(
            'ok', FALSE,
            'code', 'APPOINTMENT_SERVICES_NOT_FOUND',
            'action', 'RESCHEDULE_APPOINTMENT',
            'result_type', 'RESCHEDULING_ERROR',
            'calendar_sync', JSONB_BUILD_OBJECT('required', FALSE, 'operation', NULL)
        );
    END IF;

    v_original_professional_id := v_appointment.professional_id;
    v_target_professional_id := COALESCE(
        p_requested_professional_id,
        v_original_professional_id
    );

    SELECT COALESCE(p.display_name, p.name)
    INTO v_target_professional_name
    FROM core.professionals p
    WHERE p.business_id = p_business_id
      AND p.id = v_target_professional_id
      AND p.active = TRUE
      AND p.online_booking_enabled = TRUE
    LIMIT 1;

    IF v_target_professional_name IS NULL THEN
        RETURN JSONB_BUILD_OBJECT(
            'ok', FALSE,
            'code', 'PROFESSIONAL_NOT_AVAILABLE',
            'action', 'RESCHEDULE_APPOINTMENT',
            'result_type', 'RESCHEDULING_ERROR',
            'professional_id', v_target_professional_id,
            'calendar_sync', JSONB_BUILD_OBJECT('required', FALSE, 'operation', NULL)
        );
    END IF;

    -- --------------------------------------------------------
    -- Datas efetivas.
    -- --------------------------------------------------------
    v_today := (NOW() AT TIME ZONE v_timezone)::DATE;
    v_original_date := (v_appointment.start_at AT TIME ZONE v_timezone)::DATE;
    v_max_date := v_today + GREATEST(v_booking_horizon, 1);

    v_date_from := GREATEST(
        v_today,
        COALESCE(p_requested_date, v_original_date)
    );

    IF v_date_from > v_max_date THEN
        RETURN JSONB_BUILD_OBJECT(
            'ok', FALSE,
            'code', 'RESCHEDULE_DATE_OUTSIDE_BOOKING_HORIZON',
            'action', 'RESCHEDULE_APPOINTMENT',
            'result_type', 'RESCHEDULING_ERROR',
            'requested_date', p_requested_date,
            'maximum_date', v_max_date,
            'calendar_sync', JSONB_BUILD_OBJECT('required', FALSE, 'operation', NULL)
        );
    END IF;

    -- --------------------------------------------------------
    -- TENTATIVA 1: profissional alvo, data alvo/original.
    -- --------------------------------------------------------
    v_result := core.create_slot_offer(
        p_business_id,
        p_conversation_id,
        v_service_ids,
        v_date_from,
        v_date_from,
        v_target_professional_id,
        p_time_from,
        p_time_until,
        v_slot_limit,
        v_offer_ttl
    );

    v_call_ok := COALESCE((v_result ->> 'ok')::BOOLEAN, FALSE);

    IF NOT v_call_ok THEN
        RETURN JSONB_BUILD_OBJECT(
            'ok', FALSE,
            'code', 'RESCHEDULE_SLOT_SEARCH_FAILED',
            'action', 'RESCHEDULE_APPOINTMENT',
            'result_type', 'RESCHEDULING_ERROR',
            'result', v_result,
            'calendar_sync', JSONB_BUILD_OBJECT('required', FALSE, 'operation', NULL)
        );
    END IF;

    v_has_slots := COALESCE((v_result ->> 'count')::INTEGER, 0) > 0;

    IF v_has_slots THEN
        v_search_scope := 'TARGET_PROFESSIONAL_TARGET_DATE';
    END IF;

    -- --------------------------------------------------------
    -- TENTATIVA 2: outros profissionais na mesma data,
    -- apenas quando fallback foi autorizado.
    -- --------------------------------------------------------
    IF NOT v_has_slots AND COALESCE(p_allow_professional_fallback, FALSE) THEN
        v_result := core.create_slot_offer(
            p_business_id,
            p_conversation_id,
            v_service_ids,
            v_date_from,
            v_date_from,
            NULL,
            p_time_from,
            p_time_until,
            v_slot_limit,
            v_offer_ttl
        );

        v_call_ok := COALESCE((v_result ->> 'ok')::BOOLEAN, FALSE);

        IF NOT v_call_ok THEN
            RETURN JSONB_BUILD_OBJECT(
                'ok', FALSE,
                'code', 'RESCHEDULE_SLOT_SEARCH_FAILED',
                'action', 'RESCHEDULE_APPOINTMENT',
                'result_type', 'RESCHEDULING_ERROR',
                'result', v_result,
                'calendar_sync', JSONB_BUILD_OBJECT('required', FALSE, 'operation', NULL)
            );
        END IF;

        v_has_slots := COALESCE((v_result ->> 'count')::INTEGER, 0) > 0;

        IF v_has_slots THEN
            v_search_scope := 'ANY_PROFESSIONAL_TARGET_DATE';
        END IF;
    END IF;

    -- --------------------------------------------------------
    -- Se a data informada é a própria data original (caso mais
    -- comum quando a data foi usada apenas para identificar o
    -- compromisso), podemos ampliar para até 7 dias.
    -- Se a pessoa indicou outra data específica, respeitamos-a.
    -- --------------------------------------------------------
    IF NOT v_has_slots
       AND (p_requested_date IS NULL OR p_requested_date = v_original_date)
    THEN
        v_date_until := LEAST(v_date_from + 7, v_max_date);

        IF v_date_until > v_date_from THEN
            v_result := core.create_slot_offer(
                p_business_id,
                p_conversation_id,
                v_service_ids,
                v_date_from,
                v_date_until,
                v_target_professional_id,
                p_time_from,
                p_time_until,
                v_slot_limit,
                v_offer_ttl
            );

            v_call_ok := COALESCE((v_result ->> 'ok')::BOOLEAN, FALSE);

            IF NOT v_call_ok THEN
                RETURN JSONB_BUILD_OBJECT(
                    'ok', FALSE,
                    'code', 'RESCHEDULE_SLOT_SEARCH_FAILED',
                    'action', 'RESCHEDULE_APPOINTMENT',
                    'result_type', 'RESCHEDULING_ERROR',
                    'result', v_result,
                    'calendar_sync', JSONB_BUILD_OBJECT('required', FALSE, 'operation', NULL)
                );
            END IF;

            v_has_slots := COALESCE((v_result ->> 'count')::INTEGER, 0) > 0;

            IF v_has_slots THEN
                v_search_scope := 'TARGET_PROFESSIONAL_NEXT_7_DAYS';
            END IF;
        END IF;
    END IF;

    -- --------------------------------------------------------
    -- Último fallback: qualquer profissional nos próximos 7 dias.
    -- --------------------------------------------------------
    IF NOT v_has_slots
       AND COALESCE(p_allow_professional_fallback, FALSE)
       AND (p_requested_date IS NULL OR p_requested_date = v_original_date)
    THEN
        v_date_until := LEAST(v_date_from + 7, v_max_date);

        IF v_date_until > v_date_from THEN
            v_result := core.create_slot_offer(
                p_business_id,
                p_conversation_id,
                v_service_ids,
                v_date_from,
                v_date_until,
                NULL,
                p_time_from,
                p_time_until,
                v_slot_limit,
                v_offer_ttl
            );

            v_call_ok := COALESCE((v_result ->> 'ok')::BOOLEAN, FALSE);

            IF NOT v_call_ok THEN
                RETURN JSONB_BUILD_OBJECT(
                    'ok', FALSE,
                    'code', 'RESCHEDULE_SLOT_SEARCH_FAILED',
                    'action', 'RESCHEDULE_APPOINTMENT',
                    'result_type', 'RESCHEDULING_ERROR',
                    'result', v_result,
                    'calendar_sync', JSONB_BUILD_OBJECT('required', FALSE, 'operation', NULL)
                );
            END IF;

            v_has_slots := COALESCE((v_result ->> 'count')::INTEGER, 0) > 0;

            IF v_has_slots THEN
                v_search_scope := 'ANY_PROFESSIONAL_NEXT_7_DAYS';
            END IF;
        END IF;
    END IF;

    -- --------------------------------------------------------
    -- Nenhuma alternativa encontrada: não alteramos appointment.
    -- Também não deixamos SELECT_SLOT pendente sem oferta útil.
    -- --------------------------------------------------------
    IF NOT v_has_slots THEN
        UPDATE core.conversations c
        SET
            current_intent = NULL,
            pending_action = NULL,
            slots = '{}'::JSONB,
            context = COALESCE(c.context, '{}'::JSONB) - 'rescheduling'
        WHERE c.id = p_conversation_id
          AND c.business_id = p_business_id
          AND c.customer_id = p_customer_id
          AND c.status = 'OPEN';

        RETURN JSONB_BUILD_OBJECT(
            'ok', TRUE,
            'code', 'NO_RESCHEDULE_SLOTS',
            'action', 'RESCHEDULE_APPOINTMENT',
            'result_type', 'SLOT_OFFER',
            'source_appointment', JSONB_BUILD_OBJECT(
                'appointment_id', v_appointment.id,
                'status', v_appointment.status,
                'professional_id', v_appointment.professional_id,
                'start_at', v_appointment.start_at,
                'end_at', v_appointment.end_at
            ),
            'result', v_result,
            'calendar_sync', JSONB_BUILD_OBJECT('required', FALSE, 'operation', NULL)
        );
    END IF;

    v_slot_offer_id := NULLIF(v_result ->> 'slot_offer_id', '')::UUID;

    IF v_slot_offer_id IS NULL THEN
        RETURN JSONB_BUILD_OBJECT(
            'ok', FALSE,
            'code', 'RESCHEDULE_SLOT_OFFER_ID_MISSING',
            'action', 'RESCHEDULE_APPOINTMENT',
            'result_type', 'RESCHEDULING_ERROR',
            'result', v_result,
            'calendar_sync', JSONB_BUILD_OBJECT('required', FALSE, 'operation', NULL)
        );
    END IF;

    -- --------------------------------------------------------
    -- A partir daqui oferta + contexto precisam ficar coerentes.
    -- Falha de invariantes é excepcional e NÃO é capturada aqui:
    -- assim o PostgreSQL aborta a chamada inteira e também desfaz
    -- a criação/supersessão de offers feita acima.
    -- --------------------------------------------------------
    UPDATE core.slot_offers so
        SET metadata =
            COALESCE(so.metadata, '{}'::JSONB)
            || JSONB_BUILD_OBJECT(
                'flow_type', 'RESCHEDULE',
                'rescheduling_source_appointment_id', v_appointment.id,
                'rescheduling_source_status', v_appointment.status,
                'source_start_at', v_appointment.start_at,
                'source_end_at', v_appointment.end_at,
                'original_professional_id', v_original_professional_id,
                'requested_professional_id', p_requested_professional_id,
                'allow_professional_fallback', COALESCE(p_allow_professional_fallback, FALSE),
                'search_scope', v_search_scope,
                'prepared_at', NOW()
            )
        WHERE so.id = v_slot_offer_id
          AND so.business_id = p_business_id
          AND so.conversation_id = p_conversation_id
          AND so.status = 'ACTIVE';

    IF NOT FOUND THEN
        RAISE EXCEPTION 'RESCHEDULE_SLOT_OFFER_NOT_ACTIVE'
            USING ERRCODE = 'P0001';
    END IF;

    UPDATE core.conversations c
        SET
            context = JSONB_SET(
                COALESCE(c.context, '{}'::JSONB)
                    - 'booking'
                    - 'rebooking'
                    - 'rescheduling',
                '{rescheduling}',
                JSONB_BUILD_OBJECT(
                    'source_appointment_id', v_appointment.id,
                    'source_status', v_appointment.status,
                    'source_start_at', v_appointment.start_at,
                    'source_end_at', v_appointment.end_at,
                    'service_ids', TO_JSONB(v_service_ids),
                    'service_summary', v_service_names,
                    'professional_id', v_target_professional_id,
                    'professional_name', v_target_professional_name,
                    'slot_offer_id', v_slot_offer_id,
                    'started_at', NOW()
                ),
                TRUE
            ),
            current_intent = 'RESCHEDULE_APPOINTMENT',
            pending_action = 'SELECT_SLOT',
            slots = '{}'::JSONB
        WHERE c.id = p_conversation_id
          AND c.business_id = p_business_id
          AND c.customer_id = p_customer_id
          AND c.status = 'OPEN';

    IF NOT FOUND THEN
        RAISE EXCEPTION 'RESCHEDULE_CONVERSATION_NOT_FOUND'
            USING ERRCODE = 'P0001';
    END IF;

    RETURN JSONB_BUILD_OBJECT(
        'ok', TRUE,
        'code', 'RESCHEDULE_SLOT_OFFER_CREATED',
        'action', 'RESCHEDULE_APPOINTMENT',
        'result_type', 'SLOT_OFFER',
        'rescheduling', JSONB_BUILD_OBJECT(
            'source_appointment_id', v_appointment.id,
            'source_status', v_appointment.status,
            'source_start_at', v_appointment.start_at,
            'source_end_at', v_appointment.end_at,
            'service_ids', TO_JSONB(v_service_ids),
            'service_summary', v_service_names,
            'professional_id', v_target_professional_id,
            'professional_name', v_target_professional_name,
            'search_scope', v_search_scope
        ),
        'result', v_result,
        'calendar_sync', JSONB_BUILD_OBJECT(
            'required', FALSE,
            'operation', NULL
        )
    );
END;
$function$;


-- ============================================================
-- 2. SELECIONAR OPÇÃO E EFETIVAR REMARCAÇÃO ATOMICAMENTE
-- ============================================================

CREATE OR REPLACE FUNCTION core.select_and_reschedule_slot_offer_option(
    p_business_id UUID,
    p_conversation_id UUID,
    p_option_number INTEGER,
    p_source_channel TEXT DEFAULT NULL,
    p_source_provider TEXT DEFAULT NULL,
    p_expected_slot_offer_id UUID DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
AS $function$
DECLARE
    v_conversation core.conversations%ROWTYPE;
    v_offer core.slot_offers%ROWTYPE;
    v_source_appointment core.appointments%ROWTYPE;
    v_new_appointment core.appointments%ROWTYPE;

    v_source_appointment_id_text TEXT;
    v_source_appointment_id UUID;
    v_new_appointment_id UUID;
    v_selected_offer_id UUID;

    v_selection JSONB;
    v_confirmation JSONB;

    v_failure_code TEXT;

    v_rescheduling_enabled BOOLEAN := TRUE;
    v_rescheduling_notice_minutes INTEGER := 60;

    v_source_sync_id UUID;
    v_source_external_calendar_id TEXT;
    v_source_external_event_id TEXT;

    v_replacement_calendar_provider TEXT;
    v_replacement_external_calendar_id TEXT;

    v_calendar_delete_required BOOLEAN := FALSE;
    v_calendar_create_required BOOLEAN := FALSE;
BEGIN
    BEGIN
        -- ----------------------------------------------------
        -- 1. Conversa: lock principal para serializar a seleção.
        -- ----------------------------------------------------
        SELECT c.*
        INTO v_conversation
        FROM core.conversations c
        WHERE c.business_id = p_business_id
          AND c.id = p_conversation_id
          AND c.status = 'OPEN'
        FOR UPDATE;

        IF NOT FOUND THEN
            RETURN JSONB_BUILD_OBJECT(
                'ok', FALSE,
                'code', 'CONVERSATION_NOT_FOUND',
                'stage', 'CONVERSATION'
            );
        END IF;

        IF p_option_number IS NULL
           OR p_option_number < 1
           OR p_option_number > 50
        THEN
            RETURN JSONB_BUILD_OBJECT(
                'ok', FALSE,
                'code', 'INVALID_OPTION_NUMBER',
                'stage', 'SELECTION'
            );
        END IF;

        -- ----------------------------------------------------
        -- 2. Oferta ACTIVE que originou a remarcação.
        -- ----------------------------------------------------
        SELECT so.*
        INTO v_offer
        FROM core.slot_offers so
        WHERE so.business_id = p_business_id
          AND so.conversation_id = p_conversation_id
          AND so.status = 'ACTIVE'
          AND (
                p_expected_slot_offer_id IS NULL
                OR so.id = p_expected_slot_offer_id
          )
        ORDER BY so.created_at DESC
        LIMIT 1
        FOR UPDATE;

        IF NOT FOUND THEN
            RETURN JSONB_BUILD_OBJECT(
                'ok', FALSE,
                'code', CASE
                    WHEN p_expected_slot_offer_id IS NULL
                        THEN 'NO_ACTIVE_SLOT_OFFER'
                    ELSE 'EXPECTED_SLOT_OFFER_NOT_ACTIVE'
                END,
                'stage', 'SELECTION',
                'expected_slot_offer_id', p_expected_slot_offer_id
            );
        END IF;

        IF v_offer.expires_at <= NOW() THEN
            UPDATE core.slot_offers
            SET status = 'EXPIRED'
            WHERE business_id = p_business_id
              AND id = v_offer.id
              AND status = 'ACTIVE';

            RETURN JSONB_BUILD_OBJECT(
                'ok', FALSE,
                'code', 'SLOT_OFFER_EXPIRED',
                'stage', 'SELECTION',
                'slot_offer_id', v_offer.id
            );
        END IF;

        v_source_appointment_id_text := NULLIF(
            BTRIM(v_offer.metadata ->> 'rescheduling_source_appointment_id'),
            ''
        );

        IF v_source_appointment_id_text IS NULL THEN
            RETURN JSONB_BUILD_OBJECT(
                'ok', FALSE,
                'code', 'RESCHEDULING_SOURCE_APPOINTMENT_MISSING',
                'stage', 'RESCHEDULING',
                'slot_offer_id', v_offer.id
            );
        END IF;

        IF v_source_appointment_id_text !~
            '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$'
        THEN
            RETURN JSONB_BUILD_OBJECT(
                'ok', FALSE,
                'code', 'INVALID_RESCHEDULING_SOURCE_APPOINTMENT_ID',
                'stage', 'RESCHEDULING',
                'slot_offer_id', v_offer.id
            );
        END IF;

        v_source_appointment_id := v_source_appointment_id_text::UUID;

        -- ----------------------------------------------------
        -- 3. Appointment original precisa continuar CONFIRMED.
        -- ----------------------------------------------------
        SELECT a.*
        INTO v_source_appointment
        FROM core.appointments a
        WHERE a.business_id = p_business_id
          AND a.id = v_source_appointment_id
          AND a.customer_id = v_conversation.customer_id
        FOR UPDATE;

        IF NOT FOUND THEN
            RETURN JSONB_BUILD_OBJECT(
                'ok', FALSE,
                'code', 'RESCHEDULING_SOURCE_APPOINTMENT_NOT_FOUND',
                'stage', 'RESCHEDULING',
                'source_appointment_id', v_source_appointment_id
            );
        END IF;

        IF v_source_appointment.status <> 'CONFIRMED' THEN
            RETURN JSONB_BUILD_OBJECT(
                'ok', FALSE,
                'code', 'RESCHEDULING_SOURCE_NOT_CONFIRMED',
                'stage', 'RESCHEDULING',
                'source_appointment_id', v_source_appointment.id,
                'source_status', v_source_appointment.status
            );
        END IF;

        SELECT
            COALESCE(bs.rescheduling_enabled, TRUE),
            COALESCE(bs.rescheduling_notice_minutes, 60)
        INTO
            v_rescheduling_enabled,
            v_rescheduling_notice_minutes
        FROM core.businesses b
        LEFT JOIN core.business_settings bs
          ON bs.business_id = b.id
        WHERE b.id = p_business_id
        LIMIT 1;

        IF NOT FOUND OR v_rescheduling_enabled IS NOT TRUE THEN
            RETURN JSONB_BUILD_OBJECT(
                'ok', FALSE,
                'code', 'RESCHEDULING_DISABLED',
                'stage', 'RESCHEDULING'
            );
        END IF;

        IF NOW() >
            v_source_appointment.start_at
            - MAKE_INTERVAL(mins => GREATEST(v_rescheduling_notice_minutes, 0))
        THEN
            UPDATE core.slot_offers
            SET status = 'SUPERSEDED'
            WHERE business_id = p_business_id
              AND id = v_offer.id
              AND status = 'ACTIVE';

            UPDATE core.conversations c
            SET
                current_intent = NULL,
                pending_action = NULL,
                slots = '{}'::JSONB,
                context = COALESCE(c.context, '{}'::JSONB) - 'rescheduling'
            WHERE c.business_id = p_business_id
              AND c.id = p_conversation_id
              AND c.customer_id = v_conversation.customer_id;

            RETURN JSONB_BUILD_OBJECT(
                'ok', FALSE,
                'code', 'RESCHEDULING_NOTICE_VIOLATION',
                'stage', 'RESCHEDULING',
                'source_appointment_id', v_source_appointment.id,
                'start_at', v_source_appointment.start_at,
                'notice_minutes', v_rescheduling_notice_minutes
            );
        END IF;

        -- ----------------------------------------------------
        -- 4. Selecionar opção. A função existente revalida tudo,
        -- cria HOLD e marca a offer como SELECTED.
        -- ----------------------------------------------------
        v_selection := core.select_slot_offer_option(
            p_business_id,
            p_conversation_id,
            p_option_number,
            p_source_channel::VARCHAR,
            p_source_provider::VARCHAR
        );

        IF NOT COALESCE((v_selection ->> 'ok')::BOOLEAN, FALSE) THEN
            RETURN JSONB_BUILD_OBJECT(
                'ok', FALSE,
                'code', COALESCE(v_selection ->> 'code', 'SLOT_SELECTION_FAILED'),
                'stage', 'SELECTION',
                'selection', v_selection
            );
        END IF;

        v_selected_offer_id := NULLIF(v_selection ->> 'slot_offer_id', '')::UUID;

        IF v_selected_offer_id IS DISTINCT FROM v_offer.id THEN
            v_failure_code := 'SLOT_OFFER_MISMATCH';
            RAISE EXCEPTION 'ASSISTANT_RESCHEDULE_ROLLBACK'
                USING ERRCODE = 'P0001';
        END IF;

        IF p_expected_slot_offer_id IS NOT NULL
           AND v_selected_offer_id IS DISTINCT FROM p_expected_slot_offer_id
        THEN
            v_failure_code := 'SLOT_OFFER_MISMATCH';
            RAISE EXCEPTION 'ASSISTANT_RESCHEDULE_ROLLBACK'
                USING ERRCODE = 'P0001';
        END IF;

        v_new_appointment_id := NULLIF(
            v_selection #>> '{hold,appointment_id}',
            ''
        )::UUID;

        IF v_new_appointment_id IS NULL THEN
            v_failure_code := 'HOLD_WITHOUT_APPOINTMENT_ID';
            RAISE EXCEPTION 'ASSISTANT_RESCHEDULE_ROLLBACK'
                USING ERRCODE = 'P0001';
        END IF;

        -- ----------------------------------------------------
        -- 5. Confirmar replacement antes de liberar original.
        -- ----------------------------------------------------
        v_confirmation := core.confirm_appointment_hold(
            p_business_id,
            v_new_appointment_id
        );

        IF NOT COALESCE((v_confirmation ->> 'ok')::BOOLEAN, FALSE) THEN
            v_failure_code := COALESCE(
                v_confirmation ->> 'code',
                'APPOINTMENT_CONFIRMATION_FAILED'
            );
            RAISE EXCEPTION 'ASSISTANT_RESCHEDULE_ROLLBACK'
                USING ERRCODE = 'P0001';
        END IF;

        SELECT a.*
        INTO v_new_appointment
        FROM core.appointments a
        WHERE a.business_id = p_business_id
          AND a.id = v_new_appointment_id
        FOR UPDATE;

        IF NOT FOUND THEN
            v_failure_code := 'REPLACEMENT_APPOINTMENT_NOT_FOUND';
            RAISE EXCEPTION 'ASSISTANT_RESCHEDULE_ROLLBACK'
                USING ERRCODE = 'P0001';
        END IF;

        IF v_new_appointment.status <> 'CONFIRMED' THEN
            v_failure_code := 'REPLACEMENT_APPOINTMENT_NOT_CONFIRMED';
            RAISE EXCEPTION 'ASSISTANT_RESCHEDULE_ROLLBACK'
                USING ERRCODE = 'P0001';
        END IF;

        IF v_new_appointment.customer_id IS DISTINCT FROM v_source_appointment.customer_id THEN
            v_failure_code := 'RESCHEDULING_CUSTOMER_MISMATCH';
            RAISE EXCEPTION 'ASSISTANT_RESCHEDULE_ROLLBACK'
                USING ERRCODE = 'P0001';
        END IF;

        -- ----------------------------------------------------
        -- 6. Linhagem no novo appointment.
        -- ----------------------------------------------------
        UPDATE core.appointments a
        SET metadata = JSONB_SET(
            COALESCE(a.metadata, '{}'::JSONB),
            '{rescheduling}',
            COALESCE(a.metadata -> 'rescheduling', '{}'::JSONB)
            || JSONB_BUILD_OBJECT(
                'source_appointment_id', v_source_appointment.id,
                'slot_offer_id', v_selected_offer_id,
                'source_start_at', v_source_appointment.start_at,
                'source_end_at', v_source_appointment.end_at,
                'completed_at', NOW()
            ),
            TRUE
        )
        WHERE a.business_id = p_business_id
          AND a.id = v_new_appointment.id;

        IF NOT FOUND THEN
            v_failure_code := 'REPLACEMENT_METADATA_UPDATE_FAILED';
            RAISE EXCEPTION 'ASSISTANT_RESCHEDULE_ROLLBACK'
                USING ERRCODE = 'P0001';
        END IF;

        -- ----------------------------------------------------
        -- 7. Troca definitiva: original -> RESCHEDULED.
        -- Somente agora ele deixa de bloquear o horário antigo.
        -- ----------------------------------------------------
        UPDATE core.appointments a
        SET
            status = 'RESCHEDULED',
            metadata = JSONB_SET(
                COALESCE(a.metadata, '{}'::JSONB),
                '{rescheduling}',
                COALESCE(a.metadata -> 'rescheduling', '{}'::JSONB)
                || JSONB_BUILD_OBJECT(
                    'replacement_appointment_id', v_new_appointment.id,
                    'slot_offer_id', v_selected_offer_id,
                    'replacement_start_at', v_new_appointment.start_at,
                    'replacement_end_at', v_new_appointment.end_at,
                    'completed_at', NOW()
                ),
                TRUE
            )
        WHERE a.business_id = p_business_id
          AND a.id = v_source_appointment.id
          AND a.status = 'CONFIRMED';

        IF NOT FOUND THEN
            v_failure_code := 'SOURCE_APPOINTMENT_STATUS_CHANGED';
            RAISE EXCEPTION 'ASSISTANT_RESCHEDULE_ROLLBACK'
                USING ERRCODE = 'P0001';
        END IF;

        INSERT INTO core.appointment_events (
            business_id,
            appointment_id,
            event_type,
            from_status,
            to_status,
            actor_type,
            actor_ref,
            payload
        )
        VALUES (
            p_business_id,
            v_source_appointment.id,
            'RESCHEDULED',
            'CONFIRMED',
            'RESCHEDULED',
            'CUSTOMER',
            v_source_appointment.customer_id::TEXT,
            JSONB_BUILD_OBJECT(
                'replacement_appointment_id', v_new_appointment.id,
                'slot_offer_id', v_selected_offer_id,
                'old_start_at', v_source_appointment.start_at,
                'old_end_at', v_source_appointment.end_at,
                'new_start_at', v_new_appointment.start_at,
                'new_end_at', v_new_appointment.end_at,
                'source_channel', p_source_channel,
                'source_provider', p_source_provider
            )
        );

        -- ----------------------------------------------------
        -- 8. Encerrar estado transitório da conversa.
        -- ----------------------------------------------------
        UPDATE core.conversations c
        SET
            current_intent = NULL,
            pending_action = NULL,
            slots = '{}'::JSONB,
            context = COALESCE(c.context, '{}'::JSONB)
                - 'booking'
                - 'rebooking'
                - 'rescheduling'
        WHERE c.business_id = p_business_id
          AND c.id = p_conversation_id
          AND c.customer_id = v_source_appointment.customer_id
          AND c.status = 'OPEN';

        IF NOT FOUND THEN
            v_failure_code := 'CONVERSATION_NOT_FOUND_AFTER_RESCHEDULE';
            RAISE EXCEPTION 'ASSISTANT_RESCHEDULE_ROLLBACK'
                USING ERRCODE = 'P0001';
        END IF;

        -- ----------------------------------------------------
        -- 9. Dados do espelho de Calendar.
        -- Não alteramos Calendar dentro da transação do Core.
        -- ----------------------------------------------------
        SELECT
            cs.id,
            cs.external_calendar_id,
            cs.external_event_id
        INTO
            v_source_sync_id,
            v_source_external_calendar_id,
            v_source_external_event_id
        FROM core.appointment_calendar_syncs cs
        WHERE cs.business_id = p_business_id
          AND cs.appointment_id = v_source_appointment.id
          AND cs.provider = 'GOOGLE'
        LIMIT 1;

        v_calendar_delete_required :=
            v_source_external_event_id IS NOT NULL;

        SELECT
            p.calendar_provider,
            p.external_calendar_id
        INTO
            v_replacement_calendar_provider,
            v_replacement_external_calendar_id
        FROM core.professionals p
        WHERE p.business_id = p_business_id
          AND p.id = v_new_appointment.professional_id
        LIMIT 1;

        v_calendar_create_required :=
            v_replacement_calendar_provider = 'GOOGLE'
            AND v_replacement_external_calendar_id IS NOT NULL;

        -- Recarrega estados finais.
        SELECT a.*
        INTO v_source_appointment
        FROM core.appointments a
        WHERE a.business_id = p_business_id
          AND a.id = v_source_appointment_id;

        SELECT a.*
        INTO v_new_appointment
        FROM core.appointments a
        WHERE a.business_id = p_business_id
          AND a.id = v_new_appointment_id;

        RETURN JSONB_BUILD_OBJECT(
            'ok', TRUE,
            'code', 'APPOINTMENT_RESCHEDULED',
            'slot_offer_id', v_selected_offer_id,
            'option_number', p_option_number,
            'conversation_state', 'COMPLETED',
            'source_appointment', JSONB_BUILD_OBJECT(
                'appointment_id', v_source_appointment.id,
                'status', v_source_appointment.status,
                'customer_id', v_source_appointment.customer_id,
                'professional_id', v_source_appointment.professional_id,
                'start_at', v_source_appointment.start_at,
                'end_at', v_source_appointment.end_at
            ),
            'appointment', JSONB_BUILD_OBJECT(
                'appointment_id', v_new_appointment.id,
                'status', v_new_appointment.status,
                'customer_id', v_new_appointment.customer_id,
                'professional_id', v_new_appointment.professional_id,
                'start_at', v_new_appointment.start_at,
                'end_at', v_new_appointment.end_at,
                'total_price', v_new_appointment.total_price,
                'currency', v_new_appointment.currency,
                'total_service_minutes', v_new_appointment.total_service_minutes,
                'confirmed_at', v_new_appointment.confirmed_at
            ),
            'rescheduling', JSONB_BUILD_OBJECT(
                'completed', TRUE,
                'source_appointment_id', v_source_appointment.id,
                'replacement_appointment_id', v_new_appointment.id,
                'slot_offer_id', v_selected_offer_id
            ),
            -- O fluxo atual de Calendar do node 14 só representa
            -- uma operação simples. Remarcação exige duas ações
            -- (deletar/mover origem + criar replacement), então não
            -- o acionamos como se fosse um CREATE normal.
            'calendar_sync', JSONB_BUILD_OBJECT(
                'required', FALSE,
                'operation', NULL
            ),
            'calendar_reschedule', JSONB_BUILD_OBJECT(
                'required',
                    v_calendar_delete_required OR v_calendar_create_required,
                'source', JSONB_BUILD_OBJECT(
                    'appointment_id', v_source_appointment.id,
                    'delete_required', v_calendar_delete_required,
                    'sync_id', v_source_sync_id,
                    'external_calendar_id', v_source_external_calendar_id,
                    'external_event_id', v_source_external_event_id
                ),
                'replacement', JSONB_BUILD_OBJECT(
                    'appointment_id', v_new_appointment.id,
                    'create_required', v_calendar_create_required,
                    'external_calendar_id', v_replacement_external_calendar_id
                )
            ),
            'selection', v_selection,
            'confirmation', v_confirmation
        );

    EXCEPTION
        WHEN SQLSTATE 'P0001' THEN
            IF SQLERRM = 'ASSISTANT_RESCHEDULE_ROLLBACK' THEN
                RETURN JSONB_BUILD_OBJECT(
                    'ok', FALSE,
                    'code', 'RESCHEDULE_CONFIRMATION_FAILED',
                    'reason', COALESCE(v_failure_code, 'UNKNOWN_FAILURE'),
                    'expected_slot_offer_id', p_expected_slot_offer_id,
                    'selected_slot_offer_id', v_selected_offer_id,
                    'option_number', p_option_number,
                    'source_appointment_id', v_source_appointment_id
                );
            END IF;
            RAISE;
    END;
END;
$function$;


-- ============================================================
-- 3. SELECT_SLOT V4: DECIDE PELO METADATA DA OFERTA
-- ============================================================

CREATE OR REPLACE FUNCTION core.select_and_finalize_slot_offer_option_v4(
    p_business_id UUID,
    p_conversation_id UUID,
    p_option_number INTEGER,
    p_source_channel TEXT DEFAULT NULL,
    p_source_provider TEXT DEFAULT NULL,
    p_expected_slot_offer_id UUID DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
AS $function$
DECLARE
    v_customer_id UUID;
    v_offer core.slot_offers%ROWTYPE;
BEGIN
    -- Conversa primeiro: mantém a mesma ordem de lock do motor de offers.
    SELECT c.customer_id
    INTO v_customer_id
    FROM core.conversations c
    WHERE c.business_id = p_business_id
      AND c.id = p_conversation_id
      AND c.status = 'OPEN'
    FOR UPDATE;

    IF NOT FOUND THEN
        RETURN JSONB_BUILD_OBJECT(
            'ok', FALSE,
            'code', 'CONVERSATION_NOT_FOUND'
        );
    END IF;

    SELECT so.*
    INTO v_offer
    FROM core.slot_offers so
    WHERE so.business_id = p_business_id
      AND so.conversation_id = p_conversation_id
      AND so.status = 'ACTIVE'
      AND (
            p_expected_slot_offer_id IS NULL
            OR so.id = p_expected_slot_offer_id
      )
    ORDER BY so.created_at DESC
    LIMIT 1
    FOR UPDATE;

    IF NOT FOUND THEN
        RETURN JSONB_BUILD_OBJECT(
            'ok', FALSE,
            'code', CASE
                WHEN p_expected_slot_offer_id IS NULL
                    THEN 'NO_ACTIVE_SLOT_OFFER'
                ELSE 'EXPECTED_SLOT_OFFER_NOT_ACTIVE'
            END,
            'expected_slot_offer_id', p_expected_slot_offer_id
        );
    END IF;

    IF NULLIF(
        BTRIM(v_offer.metadata ->> 'rescheduling_source_appointment_id'),
        ''
    ) IS NOT NULL
    THEN
        RETURN core.select_and_reschedule_slot_offer_option(
            p_business_id,
            p_conversation_id,
            p_option_number,
            p_source_channel,
            p_source_provider,
            v_offer.id
        );
    END IF;

    RETURN core.select_and_confirm_slot_offer_option_v3(
        p_business_id,
        p_conversation_id,
        p_option_number,
        p_source_channel,
        p_source_provider,
        v_offer.id
    );
END;
$function$;


-- ============================================================
-- 4. DISPATCHER V3: ADICIONAR RESCHEDULE E USAR SELECT V4
-- ============================================================

CREATE OR REPLACE FUNCTION core.execute_assistant_action_v3(
    p_business_id UUID,
    p_conversation_id UUID,
    p_customer_id UUID,
    p_channel_type TEXT,
    p_provider TEXT,
    p_action TEXT,
    p_arguments JSONB
)
RETURNS JSONB
LANGUAGE plpgsql
AS $function$
DECLARE
    v_option_number INTEGER;
    v_expected_slot_offer_id UUID;

    v_appointment_id_text TEXT;
    v_appointment_id UUID;

    v_professional_id_text TEXT;
    v_requested_professional_id UUID;

    v_date_text TEXT;
    v_requested_date DATE;

    v_time_from_text TEXT;
    v_time_until_text TEXT;
    v_time_from TIME;
    v_time_until TIME;

    v_period TEXT;
    v_allow_professional_fallback BOOLEAN := FALSE;

    v_result JSONB;
    v_ok BOOLEAN;
BEGIN
    -- --------------------------------------------------------
    -- REBOOK_APPOINTMENT (appointment já CANCELLED)
    -- --------------------------------------------------------
    IF p_action = 'REBOOK_APPOINTMENT' THEN
        v_appointment_id_text := NULLIF(
            BTRIM(p_arguments ->> 'appointment_id'),
            ''
        );

        IF v_appointment_id_text IS NULL THEN
            RETURN JSONB_BUILD_OBJECT(
                'ok', FALSE,
                'code', 'APPOINTMENT_ID_REQUIRED',
                'action', 'REBOOK_APPOINTMENT',
                'result_type', 'REBOOKING_ERROR',
                'calendar_sync', JSONB_BUILD_OBJECT('required', FALSE, 'operation', NULL)
            );
        END IF;

        IF v_appointment_id_text !~
            '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$'
        THEN
            RETURN JSONB_BUILD_OBJECT(
                'ok', FALSE,
                'code', 'INVALID_APPOINTMENT_ID',
                'action', 'REBOOK_APPOINTMENT',
                'result_type', 'REBOOKING_ERROR',
                'calendar_sync', JSONB_BUILD_OBJECT('required', FALSE, 'operation', NULL)
            );
        END IF;

        v_appointment_id := v_appointment_id_text::UUID;

        RETURN core.prepare_cancelled_appointment_rebooking(
            p_business_id,
            p_conversation_id,
            p_customer_id,
            v_appointment_id
        );
    END IF;

    -- --------------------------------------------------------
    -- RESCHEDULE_APPOINTMENT (appointment ainda CONFIRMED)
    -- --------------------------------------------------------
    IF p_action = 'RESCHEDULE_APPOINTMENT' THEN
        v_appointment_id_text := NULLIF(
            BTRIM(p_arguments ->> 'appointment_id'),
            ''
        );

        IF v_appointment_id_text IS NULL THEN
            RETURN JSONB_BUILD_OBJECT(
                'ok', FALSE,
                'code', 'APPOINTMENT_ID_REQUIRED',
                'action', 'RESCHEDULE_APPOINTMENT',
                'result_type', 'RESCHEDULING_ERROR',
                'calendar_sync', JSONB_BUILD_OBJECT('required', FALSE, 'operation', NULL)
            );
        END IF;

        IF v_appointment_id_text !~
            '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$'
        THEN
            RETURN JSONB_BUILD_OBJECT(
                'ok', FALSE,
                'code', 'INVALID_APPOINTMENT_ID',
                'action', 'RESCHEDULE_APPOINTMENT',
                'result_type', 'RESCHEDULING_ERROR',
                'calendar_sync', JSONB_BUILD_OBJECT('required', FALSE, 'operation', NULL)
            );
        END IF;

        v_appointment_id := v_appointment_id_text::UUID;

        v_professional_id_text := NULLIF(
            BTRIM(p_arguments ->> 'professional_id'),
            ''
        );

        IF v_professional_id_text IS NOT NULL THEN
            IF v_professional_id_text !~
                '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$'
            THEN
                RETURN JSONB_BUILD_OBJECT(
                    'ok', FALSE,
                    'code', 'INVALID_PROFESSIONAL_ID',
                    'action', 'RESCHEDULE_APPOINTMENT',
                    'result_type', 'RESCHEDULING_ERROR',
                    'calendar_sync', JSONB_BUILD_OBJECT('required', FALSE, 'operation', NULL)
                );
            END IF;

            v_requested_professional_id := v_professional_id_text::UUID;
        END IF;

        v_date_text := NULLIF(BTRIM(p_arguments ->> 'date'), '');

        IF v_date_text IS NOT NULL THEN
            BEGIN
                v_requested_date := v_date_text::DATE;
            EXCEPTION
                WHEN OTHERS THEN
                    RETURN JSONB_BUILD_OBJECT(
                        'ok', FALSE,
                        'code', 'INVALID_RESCHEDULE_DATE',
                        'action', 'RESCHEDULE_APPOINTMENT',
                        'result_type', 'RESCHEDULING_ERROR',
                        'calendar_sync', JSONB_BUILD_OBJECT('required', FALSE, 'operation', NULL)
                    );
            END;
        END IF;

        v_time_from_text := NULLIF(BTRIM(p_arguments ->> 'time_from'), '');
        v_time_until_text := NULLIF(BTRIM(p_arguments ->> 'time_until'), '');

        IF v_time_from_text IS NOT NULL THEN
            BEGIN
                v_time_from := v_time_from_text::TIME;
            EXCEPTION
                WHEN OTHERS THEN
                    RETURN JSONB_BUILD_OBJECT(
                        'ok', FALSE,
                        'code', 'INVALID_RESCHEDULE_TIME_FROM',
                        'action', 'RESCHEDULE_APPOINTMENT',
                        'result_type', 'RESCHEDULING_ERROR',
                        'calendar_sync', JSONB_BUILD_OBJECT('required', FALSE, 'operation', NULL)
                    );
            END;
        END IF;

        IF v_time_until_text IS NOT NULL THEN
            BEGIN
                v_time_until := v_time_until_text::TIME;
            EXCEPTION
                WHEN OTHERS THEN
                    RETURN JSONB_BUILD_OBJECT(
                        'ok', FALSE,
                        'code', 'INVALID_RESCHEDULE_TIME_UNTIL',
                        'action', 'RESCHEDULE_APPOINTMENT',
                        'result_type', 'RESCHEDULING_ERROR',
                        'calendar_sync', JSONB_BUILD_OBJECT('required', FALSE, 'operation', NULL)
                    );
            END;
        END IF;

        -- "time" NÃO é tratado como novo horário aqui.
        -- No contrato atual ele também pode representar o horário usado
        -- para identificar o appointment de origem (como 09:45 no teste).
        -- Somente time_from/time_until ou period restringem a busca.
        v_period := UPPER(NULLIF(BTRIM(p_arguments ->> 'period'), ''));

        IF v_time_from IS NULL AND v_time_until IS NULL AND v_period IS NOT NULL THEN
            IF v_period IN ('MORNING', 'MANHA', 'MANHÃ') THEN
                v_time_from := TIME '06:00';
                v_time_until := TIME '12:00';
            ELSIF v_period IN ('AFTERNOON', 'TARDE') THEN
                v_time_from := TIME '12:00';
                v_time_until := TIME '18:00';
            ELSIF v_period IN ('EVENING', 'NIGHT', 'NOITE') THEN
                v_time_from := TIME '18:00';
                v_time_until := TIME '23:59:59';
            END IF;
        END IF;

        v_allow_professional_fallback :=
            LOWER(COALESCE(p_arguments ->> 'allow_professional_fallback', 'false'))
            IN ('true', '1', 'yes', 'sim');

        RETURN core.prepare_appointment_reschedule(
            p_business_id,
            p_conversation_id,
            p_customer_id,
            v_appointment_id,
            v_requested_professional_id,
            v_requested_date,
            v_time_from,
            v_time_until,
            v_allow_professional_fallback
        );
    END IF;

    -- --------------------------------------------------------
    -- Demais ações normais continuam no dispatcher anterior.
    -- --------------------------------------------------------
    IF p_action IS DISTINCT FROM 'SELECT_SLOT' THEN
        RETURN core.execute_assistant_action(
            p_business_id,
            p_conversation_id,
            p_customer_id,
            p_channel_type,
            p_provider,
            p_action,
            p_arguments
        );
    END IF;

    -- --------------------------------------------------------
    -- SELECT_SLOT: V4 decide se é booking/rebooking/rescheduling.
    -- --------------------------------------------------------
    BEGIN
        v_option_number := NULLIF(
            p_arguments ->> 'option_number',
            ''
        )::INTEGER;
    EXCEPTION
        WHEN OTHERS THEN
            RETURN JSONB_BUILD_OBJECT(
                'ok', FALSE,
                'code', 'INVALID_OPTION_NUMBER',
                'action', 'SELECT_SLOT'
            );
    END;

    IF v_option_number IS NULL THEN
        RETURN JSONB_BUILD_OBJECT(
            'ok', FALSE,
            'code', 'OPTION_NUMBER_REQUIRED',
            'action', 'SELECT_SLOT'
        );
    END IF;

    BEGIN
        v_expected_slot_offer_id := NULLIF(
            p_arguments ->> 'slot_offer_id',
            ''
        )::UUID;
    EXCEPTION
        WHEN OTHERS THEN
            RETURN JSONB_BUILD_OBJECT(
                'ok', FALSE,
                'code', 'INVALID_SLOT_OFFER_ID',
                'action', 'SELECT_SLOT'
            );
    END;

    v_result := core.select_and_finalize_slot_offer_option_v4(
        p_business_id,
        p_conversation_id,
        v_option_number,
        p_channel_type,
        p_provider,
        v_expected_slot_offer_id
    );

    v_ok := COALESCE((v_result ->> 'ok')::BOOLEAN, FALSE);

    RETURN JSONB_BUILD_OBJECT(
        'ok', v_ok,
        'action', 'SELECT_SLOT',
        'result_type', CASE
            WHEN NOT v_ok
                THEN 'SLOT_SELECTION_ERROR'
            WHEN v_result ->> 'code' = 'APPOINTMENT_RESCHEDULED'
                THEN 'APPOINTMENT_RESCHEDULED'
            ELSE 'APPOINTMENT_CONFIRMATION'
        END,
        'result', v_result,
        'calendar_sync', CASE
            WHEN v_result ? 'calendar_sync'
                THEN v_result -> 'calendar_sync'
            ELSE JSONB_BUILD_OBJECT(
                'required', v_ok,
                'operation', CASE WHEN v_ok THEN 'CREATE' ELSE NULL END,
                'appointment_id', CASE
                    WHEN v_ok THEN v_result #>> '{appointment,appointment_id}'
                    ELSE NULL
                END
            )
        END,
        'calendar_reschedule', CASE
            WHEN v_result ? 'calendar_reschedule'
                THEN v_result -> 'calendar_reschedule'
            ELSE NULL
        END
    );
END;
$function$;
