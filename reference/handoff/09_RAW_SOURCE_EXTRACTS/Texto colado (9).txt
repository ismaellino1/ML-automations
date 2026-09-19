-- ============================================================
-- 026_assistant_slot_confirmation
--
-- V3:
-- SELECT_SLOT passa a significar:
--
-- selecionar opção
-- → criar HOLD
-- → confirmar HOLD
-- → retornar appointment CONFIRMED
--
-- Tudo dentro da mesma operação do Assistant Core.
-- ============================================================


-- ============================================================
-- 1. SELECIONAR + CONFIRMAR ATOMICAMENTE
-- ============================================================

CREATE OR REPLACE FUNCTION core.select_and_confirm_slot_offer_option(
    p_business_id UUID,
    p_conversation_id UUID,
    p_option_number INTEGER,
    p_source_channel TEXT DEFAULT NULL,
    p_source_provider TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
VOLATILE
AS $$
DECLARE

    v_selection JSONB;

    v_confirmation JSONB;

    v_appointment_id UUID;

    v_failure_code TEXT;

    v_appointment core.appointments%ROWTYPE;

BEGIN

    /*
     * Este bloco funciona como subtransação.
     *
     * Se a seleção funcionar mas a confirmação falhar,
     * levantamos uma exceção controlada.
     *
     * O PostgreSQL então desfaz:
     * - criação do HOLD;
     * - marcação da oferta como SELECTED;
     * - quaisquer alterações dessa tentativa.
     *
     * Assim não deixamos estado parcial.
     */

    BEGIN

        -- ====================================================
        -- ETAPA 1 — SELECIONAR OPÇÃO E CRIAR HOLD
        -- ====================================================

        v_selection :=
            core.select_slot_offer_option(
                p_business_id,
                p_conversation_id,
                p_option_number,
                p_source_channel::VARCHAR,
                p_source_provider::VARCHAR
            );


        -- ====================================================
        -- SE A PRÓPRIA SELEÇÃO FALHOU
        --
        -- Não precisamos rollback adicional.
        -- A função original já trata:
        -- - oferta expirada;
        -- - opção inexistente;
        -- - slot tomado;
        -- - conversa inválida;
        -- etc.
        -- ====================================================

        IF NOT COALESCE(
            (v_selection ->> 'ok')::BOOLEAN,
            FALSE
        )
        THEN

            RETURN JSONB_BUILD_OBJECT(

                'ok',
                    FALSE,

                'code',
                    COALESCE(
                        v_selection ->> 'code',
                        'SLOT_SELECTION_FAILED'
                    ),

                'stage',
                    'SELECTION',

                'selection',
                    v_selection
            );

        END IF;


        -- ====================================================
        -- PEGAR APPOINTMENT CRIADO PELO HOLD
        -- ====================================================

        v_appointment_id :=
            NULLIF(
                v_selection #>> '{hold,appointment_id}',
                ''
            )::UUID;


        IF v_appointment_id IS NULL
        THEN

            v_failure_code :=
                'HOLD_WITHOUT_APPOINTMENT_ID';

            RAISE EXCEPTION
                'ASSISTANT_CONFIRM_ROLLBACK'
                USING ERRCODE = 'P0001';

        END IF;


        -- ====================================================
        -- ETAPA 2 — CONFIRMAR HOLD
        -- ====================================================

        v_confirmation :=
            core.confirm_appointment_hold(
                p_business_id,
                v_appointment_id
            );


        IF NOT COALESCE(
            (v_confirmation ->> 'ok')::BOOLEAN,
            FALSE
        )
        THEN

            v_failure_code :=
                COALESCE(
                    v_confirmation ->> 'code',
                    'APPOINTMENT_CONFIRMATION_FAILED'
                );

            /*
             * Força rollback da seleção + HOLD.
             *
             * Sem isso poderíamos terminar com:
             * slot_offer = SELECTED
             * appointment != CONFIRMED
             *
             * o que não queremos.
             */
            RAISE EXCEPTION
                'ASSISTANT_CONFIRM_ROLLBACK'
                USING ERRCODE = 'P0001';

        END IF;


        -- ====================================================
        -- RECARREGAR O APPOINTMENT REAL DO BANCO
        -- ====================================================

        SELECT a.*

        INTO v_appointment

        FROM core.appointments a

        WHERE a.business_id =
                p_business_id

          AND a.id =
                v_appointment_id

        LIMIT 1;


        IF NOT FOUND
        THEN

            v_failure_code :=
                'APPOINTMENT_NOT_FOUND_AFTER_CONFIRMATION';

            RAISE EXCEPTION
                'ASSISTANT_CONFIRM_ROLLBACK'
                USING ERRCODE = 'P0001';

        END IF;


        -- ====================================================
        -- GARANTIA FINAL DE STATUS
        -- ====================================================

        IF v_appointment.status <> 'CONFIRMED'
        THEN

            v_failure_code :=
                'APPOINTMENT_NOT_CONFIRMED_AFTER_CONFIRMATION';

            RAISE EXCEPTION
                'ASSISTANT_CONFIRM_ROLLBACK'
                USING ERRCODE = 'P0001';

        END IF;


        -- ====================================================
        -- SUCESSO
        -- ====================================================

        RETURN JSONB_BUILD_OBJECT(

            'ok',
                TRUE,

            'code',
                'APPOINTMENT_CONFIRMED',

            'slot_offer_id',
                v_selection ->> 'slot_offer_id',

            'option_number',
                p_option_number,

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

                    'total_price',
                        v_appointment.total_price,

                    'currency',
                        v_appointment.currency,

                    'total_service_minutes',
                        v_appointment.total_service_minutes,

                    'confirmed_at',
                        v_appointment.confirmed_at
                ),

            'selection',
                v_selection,

            'confirmation',
                v_confirmation
        );


    -- ========================================================
    -- ROLLBACK CONTROLADO
    -- ========================================================

    EXCEPTION

        WHEN SQLSTATE 'P0001'
        THEN

            IF SQLERRM = 'ASSISTANT_CONFIRM_ROLLBACK'
            THEN

                RETURN JSONB_BUILD_OBJECT(

                    'ok',
                        FALSE,

                    'code',
                        'SLOT_CONFIRMATION_FAILED',

                    'reason',
                        COALESCE(
                            v_failure_code,
                            'UNKNOWN_CONFIRMATION_FAILURE'
                        ),

                    'stage',
                        'CONFIRMATION',

                    'slot_offer_id',
                        v_selection ->> 'slot_offer_id',

                    'option_number',
                        p_option_number,

                    'confirmation',
                        v_confirmation
                );

            END IF;


            /*
             * Se for P0001 de outra origem,
             * não escondemos erro inesperado.
             */
            RAISE;

    END;

END;
$$;



-- ============================================================
-- 2. ATUALIZAR DISPATCHER UNIVERSAL DA V3
-- ============================================================

CREATE OR REPLACE FUNCTION core.execute_assistant_action(
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
VOLATILE
AS $$
DECLARE

    v_service_id UUID;

    v_professional_id UUID;

    v_requested_date DATE;

    v_period TEXT;

    v_requested_time TIME;

    v_time_from TIME;

    v_time_until TIME;

    v_option_number INTEGER;

    v_slot_limit INTEGER := 5;

    v_offer_ttl INTEGER := 10;

    v_slot_interval INTEGER := 15;

    v_result JSONB;

    v_result_ok BOOLEAN := FALSE;

BEGIN

    -- =========================================================
    -- SEGURANÇA MULTI-TENANT
    -- =========================================================

    IF NOT EXISTS (

        SELECT 1

        FROM core.conversations c

        WHERE c.id =
                p_conversation_id

          AND c.business_id =
                p_business_id

          AND c.customer_id =
                p_customer_id

    )
    THEN

        RETURN JSONB_BUILD_OBJECT(

            'ok',
                FALSE,

            'code',
                'INVALID_CONVERSATION_CONTEXT',

            'action',
                p_action
        );

    END IF;


    -- =========================================================
    -- NONE
    -- =========================================================

    IF p_action IS NULL
       OR p_action = 'NONE'
    THEN

        RETURN JSONB_BUILD_OBJECT(

            'ok',
                TRUE,

            'code',
                'NO_ACTION_REQUIRED',

            'action',
                'NONE',

            'result_type',
                'CONVERSATION',

            'calendar_sync',
                JSONB_BUILD_OBJECT(
                    'required', FALSE,
                    'operation', NULL
                )
        );

    END IF;


    -- =========================================================
    -- CONFIGURAÇÕES
    -- =========================================================

    SELECT

        COALESCE(
            bs.max_slots_per_offer,
            5
        ),

        COALESCE(
            bs.waitlist_offer_ttl_minutes,
            10
        ),

        COALESCE(
            bs.slot_interval_minutes,
            15
        )

    INTO

        v_slot_limit,

        v_offer_ttl,

        v_slot_interval

    FROM core.business_settings bs

    WHERE bs.business_id =
            p_business_id

    LIMIT 1;


    v_slot_limit :=
        COALESCE(
            v_slot_limit,
            5
        );


    v_offer_ttl :=
        COALESCE(
            v_offer_ttl,
            10
        );


    v_slot_interval :=
        GREATEST(
            COALESCE(
                v_slot_interval,
                15
            ),
            1
        );


    -- =========================================================
    -- ARGUMENTOS
    -- =========================================================

    v_service_id :=
        NULLIF(
            p_arguments ->> 'service_id',
            ''
        )::UUID;


    v_professional_id :=
        NULLIF(
            p_arguments ->> 'professional_id',
            ''
        )::UUID;


    v_requested_date :=
        NULLIF(
            p_arguments ->> 'date',
            ''
        )::DATE;


    v_period :=
        UPPER(
            NULLIF(
                p_arguments ->> 'period',
                ''
            )
        );


    v_requested_time :=
        NULLIF(
            p_arguments ->> 'time',
            ''
        )::TIME;


    v_time_from :=
        NULLIF(
            p_arguments ->> 'time_from',
            ''
        )::TIME;


    v_time_until :=
        NULLIF(
            p_arguments ->> 'time_until',
            ''
        )::TIME;


    v_option_number :=
        NULLIF(
            p_arguments ->> 'option_number',
            ''
        )::INTEGER;


    -- =========================================================
    -- SEARCH_AVAILABILITY
    -- =========================================================

    IF p_action = 'SEARCH_AVAILABILITY'
    THEN

        IF v_service_id IS NULL
        THEN

            RETURN JSONB_BUILD_OBJECT(

                'ok',
                    FALSE,

                'code',
                    'SERVICE_REQUIRED',

                'action',
                    p_action
            );

        END IF;


        IF v_requested_date IS NULL
        THEN

            RETURN JSONB_BUILD_OBJECT(

                'ok',
                    FALSE,

                'code',
                    'DATE_REQUIRED',

                'action',
                    p_action
            );

        END IF;


        -- =====================================================
        -- HORÁRIO EXATO → JANELA VÁLIDA
        -- =====================================================

        IF v_requested_time IS NOT NULL
           AND v_time_from IS NULL
        THEN

            v_time_from :=
                v_requested_time;

        END IF;


        IF v_time_from IS NOT NULL
           AND (
                v_time_until IS NULL
                OR v_time_until <= v_time_from
           )
        THEN

            IF v_time_from < TIME '23:59:00'
            THEN

                v_time_until :=
                    LEAST(

                        v_time_from
                        + MAKE_INTERVAL(
                            mins => v_slot_interval
                        ),

                        TIME '23:59:59'
                    );

            ELSE

                v_time_until :=
                    TIME '23:59:59';

            END IF;

        END IF;


        -- =====================================================
        -- PERÍODO
        -- =====================================================

        IF v_time_from IS NULL
        THEN

            CASE v_period

                WHEN 'MORNING'
                THEN

                    v_time_from :=
                        TIME '00:00:00';

                    v_time_until :=
                        TIME '11:59:59';


                WHEN 'AFTERNOON'
                THEN

                    v_time_from :=
                        TIME '12:00:00';

                    v_time_until :=
                        TIME '17:59:59';


                WHEN 'EVENING'
                THEN

                    v_time_from :=
                        TIME '18:00:00';

                    v_time_until :=
                        TIME '23:59:59';


                ELSE

                    v_time_from :=
                        NULL;

                    v_time_until :=
                        NULL;

            END CASE;

        END IF;


        -- =====================================================
        -- CRIAR OFERTA
        -- =====================================================

        v_result :=
            core.create_slot_offer(

                p_business_id,

                p_conversation_id,

                ARRAY[
                    v_service_id
                ]::UUID[],

                v_requested_date,

                v_requested_date,

                v_professional_id,

                v_time_from,

                v_time_until,

                v_slot_limit,

                v_offer_ttl
            );


        v_result_ok :=
            COALESCE(
                (v_result ->> 'ok')::BOOLEAN,
                FALSE
            );


        RETURN JSONB_BUILD_OBJECT(

            'ok',
                v_result_ok,

            'action',
                p_action,

            'result_type',
                'SLOT_OFFER',

            'result',
                v_result,

            'calendar_sync',
                JSONB_BUILD_OBJECT(

                    'required',
                        FALSE,

                    'operation',
                        NULL
                )
        );

    END IF;


    -- =========================================================
    -- SELECT_SLOT
    --
    -- V3:
    -- selecionar → HOLD → CONFIRMED
    -- =========================================================

    IF p_action = 'SELECT_SLOT'
    THEN

        IF v_option_number IS NULL
        THEN

            RETURN JSONB_BUILD_OBJECT(

                'ok',
                    FALSE,

                'code',
                    'OPTION_NUMBER_REQUIRED',

                'action',
                    p_action
            );

        END IF;


        v_result :=
            core.select_and_confirm_slot_offer_option(

                p_business_id,

                p_conversation_id,

                v_option_number,

                p_channel_type,

                p_provider
            );


        v_result_ok :=
            COALESCE(
                (v_result ->> 'ok')::BOOLEAN,
                FALSE
            );


        RETURN JSONB_BUILD_OBJECT(

            'ok',
                v_result_ok,

            'action',
                p_action,

            'result_type',
                CASE

                    WHEN v_result_ok
                    THEN
                        'APPOINTMENT_CONFIRMATION'

                    ELSE
                        'SLOT_SELECTION_ERROR'

                END,

            'result',
                v_result,

            'calendar_sync',
                JSONB_BUILD_OBJECT(

                    'required',
                        v_result_ok,

                    'operation',
                        CASE

                            WHEN v_result_ok
                            THEN 'CREATE'

                            ELSE NULL

                        END,

                    'appointment_id',
                        CASE

                            WHEN v_result_ok
                            THEN
                                v_result
                                #>>
                                '{appointment,appointment_id}'

                            ELSE NULL

                        END
                )
        );

    END IF;


    -- =========================================================
    -- AÇÕES AINDA NÃO IMPLEMENTADAS
    -- =========================================================

    RETURN JSONB_BUILD_OBJECT(

        'ok',
            FALSE,

        'code',
            'ACTION_NOT_IMPLEMENTED',

        'action',
            p_action,

        'result_type',
            'BUSINESS_ACTION',

        'calendar_sync',
            JSONB_BUILD_OBJECT(
                'required', FALSE,
                'operation', NULL
            )
    );

END;
$$;