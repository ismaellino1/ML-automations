-- ============================================================
-- 038_cancelled_appointment_rebooking
-- Reagendamento após cancelamento pelo profissional/empresa
-- ============================================================


-- ============================================================
-- 1. PREPARAR OFERTA DE REAGENDAMENTO
-- ============================================================

CREATE OR REPLACE FUNCTION
core.prepare_cancelled_appointment_rebooking(
    p_business_id UUID,
    p_conversation_id UUID,
    p_customer_id UUID,
    p_appointment_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE

    v_appointment core.appointments%ROWTYPE;

    v_service_ids UUID[];
    v_service_names TEXT;

    v_professional_id UUID;
    v_professional_name TEXT;

    v_cancellation_actor_type TEXT;

    v_timezone TEXT := 'UTC';

    v_today DATE;
    v_original_date DATE;

    v_date_from DATE;
    v_date_until DATE;
    v_max_date DATE;

    v_slot_limit INTEGER := 5;
    v_offer_ttl INTEGER := 10;
    v_booking_horizon INTEGER := 60;

    v_result JSONB;
    v_result_ok BOOLEAN := FALSE;

BEGIN

    -- ========================================================
    -- VALIDAR CONTEXTO MULTI-TENANT
    -- ========================================================

    IF NOT EXISTS (

        SELECT 1

        FROM core.conversations c

        WHERE c.id = p_conversation_id
          AND c.business_id = p_business_id
          AND c.customer_id = p_customer_id
          AND c.status = 'OPEN'

    )
    THEN

        RETURN JSONB_BUILD_OBJECT(
            'ok', FALSE,
            'code', 'INVALID_CONVERSATION_CONTEXT',
            'action', 'REBOOK_APPOINTMENT',
            'result_type', 'REBOOKING_ERROR',
            'calendar_sync',
                JSONB_BUILD_OBJECT(
                    'required', FALSE,
                    'operation', NULL
                )
        );

    END IF;


    -- ========================================================
    -- CONFIGURAÇÕES DA EMPRESA
    -- ========================================================

    SELECT
        COALESCE(b.timezone, 'UTC'),

        COALESCE(
            bs.max_slots_per_offer,
            5
        ),

        COALESCE(
            bs.waitlist_offer_ttl_minutes,
            10
        ),

        COALESCE(
            bs.maximum_booking_horizon_days,
            60
        )

    INTO
        v_timezone,
        v_slot_limit,
        v_offer_ttl,
        v_booking_horizon

    FROM core.businesses b

    LEFT JOIN core.business_settings bs
      ON bs.business_id = b.id

    WHERE b.id = p_business_id

    LIMIT 1;


    IF NOT FOUND
    THEN

        RETURN JSONB_BUILD_OBJECT(
            'ok', FALSE,
            'code', 'BUSINESS_NOT_FOUND',
            'action', 'REBOOK_APPOINTMENT',
            'result_type', 'REBOOKING_ERROR',
            'calendar_sync',
                JSONB_BUILD_OBJECT(
                    'required', FALSE,
                    'operation', NULL
                )
        );

    END IF;


    -- ========================================================
    -- CARREGAR APPOINTMENT
    --
    -- O appointment PRECISA pertencer à empresa e ao cliente.
    -- ========================================================

    SELECT a.*
    INTO v_appointment

    FROM core.appointments a

    WHERE a.id = p_appointment_id
      AND a.business_id = p_business_id
      AND a.customer_id = p_customer_id

    LIMIT 1;


    IF NOT FOUND
    THEN

        RETURN JSONB_BUILD_OBJECT(
            'ok', FALSE,
            'code', 'APPOINTMENT_NOT_FOUND_OR_NOT_OWNED',
            'action', 'REBOOK_APPOINTMENT',
            'result_type', 'REBOOKING_ERROR',
            'calendar_sync',
                JSONB_BUILD_OBJECT(
                    'required', FALSE,
                    'operation', NULL
                )
        );

    END IF;


    -- ========================================================
    -- PRECISA ESTAR CANCELADO
    -- ========================================================

    IF v_appointment.status <> 'CANCELLED'
    THEN

        RETURN JSONB_BUILD_OBJECT(

            'ok', FALSE,

            'code',
                'APPOINTMENT_NOT_CANCELLED',

            'action',
                'REBOOK_APPOINTMENT',

            'result_type',
                'REBOOKING_ERROR',

            'appointment_id',
                v_appointment.id,

            'appointment_status',
                v_appointment.status,

            'calendar_sync',
                JSONB_BUILD_OBJECT(
                    'required', FALSE,
                    'operation', NULL
                )
        );

    END IF;


    -- ========================================================
    -- VALIDAR ORIGEM DO CANCELAMENTO
    --
    -- Esse botão só deve funcionar quando o cancelamento
    -- veio do profissional ou da empresa.
    -- ========================================================

    SELECT ac.actor_type
    INTO v_cancellation_actor_type

    FROM core.appointment_cancellations ac

    WHERE ac.business_id = p_business_id
      AND ac.appointment_id = p_appointment_id

    LIMIT 1;


    IF v_cancellation_actor_type IS NULL
    THEN

        RETURN JSONB_BUILD_OBJECT(
            'ok', FALSE,
            'code', 'CANCELLATION_RECORD_NOT_FOUND',
            'action', 'REBOOK_APPOINTMENT',
            'result_type', 'REBOOKING_ERROR',
            'calendar_sync',
                JSONB_BUILD_OBJECT(
                    'required', FALSE,
                    'operation', NULL
                )
        );

    END IF;


    IF v_cancellation_actor_type NOT IN (
        'PROFESSIONAL',
        'BUSINESS'
    )
    THEN

        RETURN JSONB_BUILD_OBJECT(
            'ok', FALSE,
            'code', 'REBOOKING_NOT_ALLOWED_FOR_CANCELLATION_ACTOR',
            'action', 'REBOOK_APPOINTMENT',
            'result_type', 'REBOOKING_ERROR',
            'actor_type', v_cancellation_actor_type,
            'calendar_sync',
                JSONB_BUILD_OBJECT(
                    'required', FALSE,
                    'operation', NULL
                )
        );

    END IF;


    -- ========================================================
    -- SERVIÇOS DO APPOINTMENT
    --
    -- Usa os snapshots históricos do appointment.
    -- ========================================================

    SELECT
        ARRAY_AGG(
            ai.service_id
            ORDER BY ai.display_order
        ),

        STRING_AGG(
            ai.service_name_snapshot,
            ' + '
            ORDER BY ai.display_order
        )

    INTO
        v_service_ids,
        v_service_names

    FROM core.appointment_items ai

    WHERE ai.business_id = p_business_id
      AND ai.appointment_id = p_appointment_id;


    IF v_service_ids IS NULL
       OR CARDINALITY(v_service_ids) = 0
    THEN

        RETURN JSONB_BUILD_OBJECT(
            'ok', FALSE,
            'code', 'APPOINTMENT_SERVICES_NOT_FOUND',
            'action', 'REBOOK_APPOINTMENT',
            'result_type', 'REBOOKING_ERROR',
            'calendar_sync',
                JSONB_BUILD_OBJECT(
                    'required', FALSE,
                    'operation', NULL
                )
        );

    END IF;


    -- ========================================================
    -- PROFISSIONAL ORIGINAL
    -- ========================================================

    v_professional_id :=
        v_appointment.professional_id;


    SELECT
        COALESCE(
            p.display_name,
            p.name
        )

    INTO
        v_professional_name

    FROM core.professionals p

    WHERE p.business_id = p_business_id
      AND p.id = v_professional_id

    LIMIT 1;


    IF v_professional_name IS NULL
    THEN

        RETURN JSONB_BUILD_OBJECT(
            'ok', FALSE,
            'code', 'PROFESSIONAL_NOT_FOUND',
            'action', 'REBOOK_APPOINTMENT',
            'result_type', 'REBOOKING_ERROR',
            'calendar_sync',
                JSONB_BUILD_OBJECT(
                    'required', FALSE,
                    'operation', NULL
                )
        );

    END IF;


    -- ========================================================
    -- DATAS
    --
    -- 1º tenta a própria data cancelada.
    -- Se ela já passou, começa de hoje.
    -- ========================================================

    v_today :=
        (
            NOW()
            AT TIME ZONE v_timezone
        )::DATE;


    v_original_date :=
        (
            v_appointment.start_at
            AT TIME ZONE v_timezone
        )::DATE;


    v_date_from :=
        GREATEST(
            v_today,
            v_original_date
        );


    v_max_date :=
        v_today
        + GREATEST(
            v_booking_horizon,
            1
        );


    v_date_from :=
        LEAST(
            v_date_from,
            v_max_date
        );


    -- ========================================================
    -- PRIMEIRA TENTATIVA:
    -- mesma data do compromisso cancelado
    -- ========================================================

    v_result :=
        core.create_slot_offer(

            p_business_id,

            p_conversation_id,

            v_service_ids,

            v_date_from,

            v_date_from,

            v_professional_id,

            NULL,

            NULL,

            v_slot_limit,

            v_offer_ttl
        );


    v_result_ok :=
        COALESCE(
            (v_result ->> 'ok')::BOOLEAN,
            FALSE
        );


    -- ========================================================
    -- FALLBACK:
    -- se não houver horário na mesma data,
    -- procurar nos próximos 7 dias.
    -- ========================================================

    IF v_result_ok IS NOT TRUE
    THEN

        v_date_until :=
            LEAST(
                v_date_from + 7,
                v_max_date
            );


        IF v_date_until > v_date_from
        THEN

            v_result :=
                core.create_slot_offer(

                    p_business_id,

                    p_conversation_id,

                    v_service_ids,

                    v_date_from,

                    v_date_until,

                    v_professional_id,

                    NULL,

                    NULL,

                    v_slot_limit,

                    v_offer_ttl
                );


            v_result_ok :=
                COALESCE(
                    (v_result ->> 'ok')::BOOLEAN,
                    FALSE
                );

        END IF;

    END IF;


    -- ========================================================
    -- MARCAR CONTEXTO DE REBOOK
    --
    -- Não usamos o booking antigo como fonte de verdade.
    -- Guardamos apenas vínculo/auditoria.
    -- ========================================================

    UPDATE core.conversations

    SET
        context =
            JSONB_SET(

                COALESCE(
                    context,
                    '{}'::JSONB
                ),

                '{rebooking}',

                JSONB_BUILD_OBJECT(

                    'source_appointment_id',
                        p_appointment_id,

                    'source_status',
                        'CANCELLED',

                    'professional_id',
                        v_professional_id,

                    'service_ids',
                        TO_JSONB(
                            v_service_ids
                        ),

                    'started_at',
                        NOW()
                ),

                TRUE
            ),

        current_intent =
            'REBOOK_APPOINTMENT',

        pending_action =
            CASE
                WHEN v_result_ok
                    THEN 'SELECT_SLOT'
                ELSE NULL
            END,

        version =
            version + 1,

        updated_at =
            NOW()

    WHERE id = p_conversation_id
      AND business_id = p_business_id
      AND customer_id = p_customer_id;


    -- ========================================================
    -- RETORNO COMPATÍVEL COM RESPONSE ENGINE
    -- ========================================================

    RETURN JSONB_BUILD_OBJECT(

        'ok',
            v_result_ok,

        'action',
            'REBOOK_APPOINTMENT',

        'result_type',
            'SLOT_OFFER',

        'rebooking',
            JSONB_BUILD_OBJECT(

                'source_appointment_id',
                    p_appointment_id,

                'service_ids',
                    TO_JSONB(
                        v_service_ids
                    ),

                'service_summary',
                    v_service_names,

                'professional_id',
                    v_professional_id,

                'professional_name',
                    v_professional_name,

                'original_date',
                    v_original_date,

                'search_date_from',
                    v_date_from,

                'search_date_until',
                    COALESCE(
                        v_date_until,
                        v_date_from
                    )
            ),

        'result',
            v_result,

        'calendar_sync',
            JSONB_BUILD_OBJECT(
                'required', FALSE,
                'operation', NULL
            )
    );

END;
$$;



-- ============================================================
-- 2. ATUALIZAR DISPATCHER V3
--
-- SELECT_SLOT continua exatamente com a proteção existente.
-- REBOOK_APPOINTMENT passa a ser determinístico.
-- Demais ações continuam indo para o dispatcher antigo.
-- ============================================================

CREATE OR REPLACE FUNCTION
core.execute_assistant_action_v3(
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
AS $$
DECLARE

    v_option_number INTEGER;
    v_expected_slot_offer_id UUID;

    v_appointment_id_text TEXT;
    v_appointment_id UUID;

    v_result JSONB;
    v_ok BOOLEAN;

BEGIN

    -- ========================================================
    -- REBOOK_APPOINTMENT
    -- ========================================================

    IF p_action = 'REBOOK_APPOINTMENT'
    THEN

        v_appointment_id_text :=
            NULLIF(
                BTRIM(
                    p_arguments
                    ->>
                    'appointment_id'
                ),
                ''
            );


        IF v_appointment_id_text IS NULL
        THEN

            RETURN JSONB_BUILD_OBJECT(
                'ok', FALSE,
                'code', 'APPOINTMENT_ID_REQUIRED',
                'action', 'REBOOK_APPOINTMENT',
                'result_type', 'REBOOKING_ERROR',
                'calendar_sync',
                    JSONB_BUILD_OBJECT(
                        'required', FALSE,
                        'operation', NULL
                    )
            );

        END IF;


        -- UUID defensivo.
        IF v_appointment_id_text !~
            '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$'
        THEN

            RETURN JSONB_BUILD_OBJECT(
                'ok', FALSE,
                'code', 'INVALID_APPOINTMENT_ID',
                'action', 'REBOOK_APPOINTMENT',
                'result_type', 'REBOOKING_ERROR',
                'calendar_sync',
                    JSONB_BUILD_OBJECT(
                        'required', FALSE,
                        'operation', NULL
                    )
            );

        END IF;


        v_appointment_id :=
            v_appointment_id_text::UUID;


        RETURN
            core.prepare_cancelled_appointment_rebooking(
                p_business_id,
                p_conversation_id,
                p_customer_id,
                v_appointment_id
            );

    END IF;


    -- ========================================================
    -- AÇÕES NORMAIS
    --
    -- Tudo que não for SELECT_SLOT continua no dispatcher
    -- antigo, exatamente como antes.
    -- ========================================================

    IF p_action IS DISTINCT FROM 'SELECT_SLOT'
    THEN

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


    -- ========================================================
    -- SELECT_SLOT
    -- Proteção V3 existente mantida.
    -- ========================================================

    v_option_number :=
        NULLIF(
            p_arguments
            ->>
            'option_number',
            ''
        )::INTEGER;


    IF v_option_number IS NULL
    THEN

        RETURN JSONB_BUILD_OBJECT(
            'ok', FALSE,
            'code', 'OPTION_NUMBER_REQUIRED',
            'action', 'SELECT_SLOT'
        );

    END IF;


    v_expected_slot_offer_id :=
        NULLIF(
            p_arguments
            ->>
            'slot_offer_id',
            ''
        )::UUID;


    v_result :=
        core.select_and_confirm_slot_offer_option_v3(
            p_business_id,
            p_conversation_id,
            v_option_number,
            p_channel_type,
            p_provider,
            v_expected_slot_offer_id
        );


    v_ok :=
        COALESCE(
            (v_result ->> 'ok')::BOOLEAN,
            FALSE
        );


    RETURN JSONB_BUILD_OBJECT(

        'ok',
            v_ok,

        'action',
            'SELECT_SLOT',

        'result_type',
            CASE
                WHEN v_ok
                    THEN 'APPOINTMENT_CONFIRMATION'
                ELSE 'SLOT_SELECTION_ERROR'
            END,

        'result',
            v_result,

        'calendar_sync',
            JSONB_BUILD_OBJECT(

                'required',
                    v_ok,

                'operation',
                    CASE
                        WHEN v_ok
                            THEN 'CREATE'
                        ELSE NULL
                    END,

                'appointment_id',
                    CASE
                        WHEN v_ok
                            THEN
                                v_result
                                #>>
                                '{appointment,appointment_id}'
                        ELSE NULL
                    END
            )
    );

END;
$$;