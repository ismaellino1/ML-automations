-- 039_exclude_cancelled_slot_from_rebooking
-- Exclui somente do REBOOK o intervalo exato do appointment cancelado.
-- O horário continua disponível normalmente para outros clientes/fluxos.

CREATE OR REPLACE FUNCTION core.prune_cancelled_rebooking_slot_offer(
    p_business_id UUID,
    p_slot_offer_result JSONB,
    p_source_appointment_id UUID,
    p_excluded_start TIMESTAMPTZ,
    p_excluded_end TIMESTAMPTZ,
    p_max_options INTEGER
)
RETURNS JSONB
LANGUAGE plpgsql
AS $function$
DECLARE
    v_result JSONB := COALESCE(p_slot_offer_result, '{}'::JSONB);
    v_slot_offer_id UUID;
    v_filtered_options JSONB := '[]'::JSONB;
    v_allowed_option_numbers INTEGER[] := ARRAY[]::INTEGER[];
    v_option_count INTEGER := 0;
BEGIN
    -- Se a criação da oferta já falhou, não há nada para podar.
    IF COALESCE((v_result ->> 'ok')::BOOLEAN, FALSE) IS NOT TRUE
    THEN
        RETURN v_result;
    END IF;

    v_slot_offer_id :=
        NULLIF(v_result ->> 'slot_offer_id', '')::UUID;

    IF v_slot_offer_id IS NULL
    THEN
        RETURN v_result || JSONB_BUILD_OBJECT(
            'ok', FALSE,
            'code', 'REBOOKING_SLOT_OFFER_ID_MISSING'
        );
    END IF;

    -- Segurança multi-tenant: só altera uma oferta da empresa informada.
    IF NOT EXISTS (
        SELECT 1
        FROM core.slot_offers so
        WHERE so.id = v_slot_offer_id
          AND so.business_id = p_business_id
    )
    THEN
        RETURN v_result || JSONB_BUILD_OBJECT(
            'ok', FALSE,
            'code', 'REBOOKING_SLOT_OFFER_NOT_OWNED'
        );
    END IF;

    -- Mantém a ordem original da oferta, remove SOMENTE o intervalo
    -- exatamente igual ao appointment cancelado e limita à quantidade
    -- configurada para apresentação ao cliente.
    SELECT
        COALESCE(
            JSONB_AGG(q.option_json ORDER BY q.ordinality),
            '[]'::JSONB
        )
    INTO v_filtered_options
    FROM (
        SELECT
            e.option_json,
            e.ordinality
        FROM JSONB_ARRAY_ELEMENTS(
                 COALESCE(v_result -> 'options', '[]'::JSONB)
             ) WITH ORDINALITY AS e(option_json, ordinality)
        WHERE
            (
                NULLIF(e.option_json ->> 'start_at', '')::TIMESTAMPTZ
                IS DISTINCT FROM p_excluded_start
            )
            OR
            (
                NULLIF(e.option_json ->> 'end_at', '')::TIMESTAMPTZ
                IS DISTINCT FROM p_excluded_end
            )
        ORDER BY e.ordinality
        LIMIT GREATEST(COALESCE(p_max_options, 5), 1)
    ) q;

    v_option_count := JSONB_ARRAY_LENGTH(v_filtered_options);

    SELECT
        COALESCE(
            ARRAY_AGG((e.option_json ->> 'option_number')::INTEGER),
            ARRAY[]::INTEGER[]
        )
    INTO v_allowed_option_numbers
    FROM JSONB_ARRAY_ELEMENTS(v_filtered_options) AS e(option_json)
    WHERE NULLIF(e.option_json ->> 'option_number', '') IS NOT NULL;

    -- Banco e JSON precisam representar exatamente as mesmas opções.
    DELETE FROM core.slot_offer_options soo
    WHERE soo.business_id = p_business_id
      AND soo.slot_offer_id = v_slot_offer_id
      AND NOT (
          soo.option_number = ANY(v_allowed_option_numbers)
      );

    IF v_option_count = 0
    THEN
        -- A única possibilidade encontrada era o próprio horário cancelado.
        -- Remove a oferta vazia para que o caller possa executar o fallback.
        DELETE FROM core.slot_offers so
        WHERE so.id = v_slot_offer_id
          AND so.business_id = p_business_id;

        RETURN
            v_result
            || JSONB_BUILD_OBJECT(
                'ok', FALSE,
                'code', 'NO_ALTERNATIVE_SLOTS_AFTER_CANCELLED_INTERVAL_EXCLUSION',
                'options', '[]'::JSONB,
                'option_count', 0,
                'excluded_source_appointment_id', p_source_appointment_id,
                'excluded_start_at', p_excluded_start,
                'excluded_end_at', p_excluded_end
            );
    END IF;

    UPDATE core.slot_offers so
    SET
        option_count = v_option_count,
        metadata =
            COALESCE(so.metadata, '{}'::JSONB)
            || JSONB_BUILD_OBJECT(
                'rebooking_source_appointment_id', p_source_appointment_id,
                'excluded_cancelled_interval',
                    JSONB_BUILD_OBJECT(
                        'start_at', p_excluded_start,
                        'end_at', p_excluded_end
                    )
            ),
        updated_at = NOW()
    WHERE so.id = v_slot_offer_id
      AND so.business_id = p_business_id;

    v_result :=
        JSONB_SET(
            v_result,
            '{options}',
            v_filtered_options,
            TRUE
        );

    v_result :=
        JSONB_SET(
            v_result,
            '{option_count}',
            TO_JSONB(v_option_count),
            TRUE
        );

    RETURN
        v_result
        || JSONB_BUILD_OBJECT(
            'excluded_source_appointment_id', p_source_appointment_id,
            'excluded_start_at', p_excluded_start,
            'excluded_end_at', p_excluded_end
        );
END;
$function$;

CREATE OR REPLACE FUNCTION core.prepare_cancelled_appointment_rebooking(p_business_id uuid, p_conversation_id uuid, p_customer_id uuid, p_appointment_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
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
    v_generation_limit INTEGER := 6;
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


    v_generation_limit :=
        GREATEST(
            COALESCE(v_slot_limit, 5),
            1
        ) + 1;


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

            v_generation_limit,

            v_offer_ttl
        );


    v_result :=
        core.prune_cancelled_rebooking_slot_offer(
            p_business_id,
            v_result,
            p_appointment_id,
            v_appointment.start_at,
            v_appointment.end_at,
            v_slot_limit
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

                    v_generation_limit,

                    v_offer_ttl
                );


            v_result :=
                core.prune_cancelled_rebooking_slot_offer(
                    p_business_id,
                    v_result,
                    p_appointment_id,
                    v_appointment.start_at,
                    v_appointment.end_at,
                    v_slot_limit
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
$function$
