-- ============================================================
-- ML AUTOMAÇÕES
-- Migration: 017_slot_generation_engine
--
-- Finalidade:
-- Gerar automaticamente os próximos horários disponíveis
-- para um conjunto de serviços.
--
-- Usa como fonte de verdade:
-- - businesses
-- - business_settings
-- - professionals
-- - services
-- - professional_services
-- - business_hours
-- - professional_hours
-- - availability_overrides
-- - appointments
-- - check_slot_availability()
-- ============================================================


CREATE OR REPLACE FUNCTION core.get_available_slots(

    p_business_id UUID,

    p_service_ids UUID[],

    p_date_from DATE,

    p_date_until DATE,

    -- NULL = qualquer profissional compatível.
    p_professional_id UUID DEFAULT NULL,

    -- Filtros opcionais do cliente.
    -- Exemplo:
    -- "depois das 15h"
    -- p_time_from = 15:00
    --
    -- "entre 14h e 18h"
    -- p_time_from = 14:00
    -- p_time_until = 18:00
    p_time_from TIME DEFAULT NULL,

    p_time_until TIME DEFAULT NULL,

    -- NULL = usa max_slots_per_offer da empresa.
    p_limit INTEGER DEFAULT NULL

)
RETURNS JSONB

LANGUAGE plpgsql

AS $$

DECLARE

    -- ========================================================
    -- CONFIGURAÇÃO
    -- ========================================================

    v_business_status VARCHAR(30);

    v_timezone TEXT;

    v_slot_interval INTEGER;

    v_minimum_notice INTEGER;

    v_booking_horizon INTEGER;

    v_default_limit INTEGER;

    v_limit INTEGER;


    -- ========================================================
    -- DATAS EFETIVAS
    -- ========================================================

    v_today_local DATE;

    v_date_from DATE;

    v_date_until DATE;

    v_max_date DATE;


    -- ========================================================
    -- SERVIÇOS
    -- ========================================================

    v_requested_count INTEGER;

    v_unique_service_count INTEGER;

    v_valid_service_count INTEGER;


    -- ========================================================
    -- PROFISSIONAIS E RESULTADOS
    -- ========================================================

    v_professionals JSONB;

    v_prof RECORD;

    v_candidate TIMESTAMP;

    v_start_at TIMESTAMPTZ;

    v_end_at TIMESTAMPTZ;

    v_local_end TIMESTAMP;

    v_availability JSONB;

    v_slots JSONB := '[]'::JSONB;

    v_found INTEGER := 0;

BEGIN


    -- ========================================================
    -- 1. VALIDAR EMPRESA E CARREGAR CONFIGURAÇÃO
    -- ========================================================

    SELECT
        b.status,
        b.timezone,

        COALESCE(
            bs.slot_interval_minutes,
            15
        ),

        COALESCE(
            bs.minimum_booking_notice_minutes,
            0
        ),

        COALESCE(
            bs.maximum_booking_horizon_days,
            60
        ),

        COALESCE(
            bs.max_slots_per_offer,
            5
        )

    INTO
        v_business_status,
        v_timezone,
        v_slot_interval,
        v_minimum_notice,
        v_booking_horizon,
        v_default_limit

    FROM core.businesses b

    LEFT JOIN core.business_settings bs
        ON bs.business_id = b.id

    WHERE b.id = p_business_id;


    IF NOT FOUND THEN

        RETURN jsonb_build_object(
            'ok', FALSE,
            'code', 'BUSINESS_NOT_FOUND',
            'slots', '[]'::JSONB
        );

    END IF;


    IF v_business_status <> 'ACTIVE' THEN

        RETURN jsonb_build_object(
            'ok', FALSE,
            'code', 'BUSINESS_NOT_ACTIVE',
            'slots', '[]'::JSONB
        );

    END IF;


    -- ========================================================
    -- 2. VALIDAR SERVIÇOS RECEBIDOS
    -- ========================================================

    v_requested_count :=
        COALESCE(
            cardinality(p_service_ids),
            0
        );


    IF v_requested_count = 0 THEN

        RETURN jsonb_build_object(
            'ok', FALSE,
            'code', 'NO_SERVICES_SELECTED',
            'slots', '[]'::JSONB
        );

    END IF;


    SELECT COUNT(DISTINCT service_id)::INTEGER

    INTO v_unique_service_count

    FROM unnest(p_service_ids)
        AS x(service_id);


    -- Evita comportamento ambíguo como:
    --
    -- [CORTE, CORTE]
    --
    -- Se no futuro quisermos quantidade,
    -- modelamos isso explicitamente.
    IF v_unique_service_count <> v_requested_count THEN

        RETURN jsonb_build_object(
            'ok', FALSE,
            'code', 'DUPLICATE_SERVICE_IDS',
            'slots', '[]'::JSONB
        );

    END IF;


    SELECT COUNT(*)::INTEGER

    INTO v_valid_service_count

    FROM unnest(p_service_ids)
        AS requested(service_id)

    JOIN core.services s
        ON s.id = requested.service_id
       AND s.business_id = p_business_id
       AND s.active = TRUE
       AND s.online_booking_enabled = TRUE;


    IF v_valid_service_count <> v_requested_count THEN

        RETURN jsonb_build_object(
            'ok', FALSE,
            'code', 'INVALID_OR_UNAVAILABLE_SERVICE',
            'slots', '[]'::JSONB
        );

    END IF;


    -- ========================================================
    -- 3. VALIDAR INTERVALO DE DATAS
    -- ========================================================

    IF p_date_from IS NULL
       OR p_date_until IS NULL
       OR p_date_until < p_date_from
    THEN

        RETURN jsonb_build_object(
            'ok', FALSE,
            'code', 'INVALID_DATE_RANGE',
            'slots', '[]'::JSONB
        );

    END IF;


    -- Horário local atual do estabelecimento.
    v_today_local :=
        (
            NOW()
            AT TIME ZONE v_timezone
        )::DATE;


    v_max_date :=
        v_today_local
        + v_booking_horizon;


    -- Não procuramos no passado.
    v_date_from :=
        GREATEST(
            p_date_from,
            v_today_local
        );


    -- Nem além da política da empresa.
    v_date_until :=
        LEAST(
            p_date_until,
            v_max_date
        );


    IF v_date_from > v_date_until THEN

        RETURN jsonb_build_object(
            'ok', TRUE,
            'code', 'NO_SLOTS',
            'count', 0,
            'slots', '[]'::JSONB
        );

    END IF;


    -- ========================================================
    -- 4. VALIDAR JANELA DE HORÁRIO
    -- ========================================================

    IF p_time_from IS NOT NULL
       AND p_time_until IS NOT NULL
       AND p_time_from >= p_time_until
    THEN

        RETURN jsonb_build_object(
            'ok', FALSE,
            'code', 'INVALID_TIME_WINDOW',
            'slots', '[]'::JSONB
        );

    END IF;


    -- ========================================================
    -- 5. DEFINIR LIMITE
    -- ========================================================

    v_limit :=
        COALESCE(
            p_limit,
            v_default_limit,
            5
        );


    -- Proteção contra consulta exagerada.
    v_limit :=
        LEAST(
            GREATEST(
                v_limit,
                1
            ),
            50
        );


    -- ========================================================
    -- 6. PRÉ-CALCULAR PROFISSIONAIS COMPATÍVEIS
    --
    -- Fazemos isso uma única vez.
    --
    -- Depois o loop de horários trabalha em memória com
    -- esse pequeno conjunto.
    -- ========================================================

    SELECT COALESCE(

        jsonb_agg(

            jsonb_build_object(

                'professional_id',
                    q.professional_id,

                'professional_name',
                    q.professional_name,

                'display_order',
                    q.display_order,

                'total_service_minutes',
                    q.total_service_minutes,

                'total_price',
                    q.total_price,

                'currency',
                    q.currency,

                'buffer_before_minutes',
                    q.buffer_before_minutes,

                'buffer_after_minutes',
                    q.buffer_after_minutes

            )

            ORDER BY
                q.display_order,
                q.professional_name

        ),

        '[]'::JSONB

    )

    INTO v_professionals

    FROM (

        SELECT

            p.id
                AS professional_id,

            COALESCE(
                p.display_name,
                p.name
            )
                AS professional_name,

            COALESCE(
                p.display_order,
                0
            )
                AS display_order,

            SUM(
                COALESCE(
                    ps.duration_minutes_override,
                    s.duration_minutes
                )
            )::INTEGER
                AS total_service_minutes,

            SUM(
                COALESCE(
                    ps.price_override,
                    s.price
                )
            )::NUMERIC(10,2)
                AS total_price,

            MIN(s.currency)::TEXT
                AS currency,

            COALESCE(
                MAX(s.buffer_before_minutes),
                0
            )::INTEGER
                AS buffer_before_minutes,

            COALESCE(
                MAX(s.buffer_after_minutes),
                0
            )::INTEGER
                AS buffer_after_minutes

        FROM core.professionals p

        JOIN unnest(p_service_ids)
            AS requested(service_id)
            ON TRUE

        JOIN core.services s
            ON s.business_id =
                    p_business_id

           AND s.id =
                    requested.service_id

           AND s.active = TRUE

           AND s.online_booking_enabled = TRUE

        JOIN core.professional_services ps
            ON ps.business_id =
                    p_business_id

           AND ps.professional_id =
                    p.id

           AND ps.service_id =
                    s.id

           AND ps.active = TRUE

           AND ps.online_booking_enabled = TRUE

        WHERE p.business_id =
                p_business_id

          AND p.active = TRUE

          AND p.online_booking_enabled = TRUE

          AND (
                p_professional_id IS NULL
                OR
                p.id = p_professional_id
          )

        GROUP BY
            p.id,
            p.display_name,
            p.name,
            p.display_order

        HAVING COUNT(*) =
            v_requested_count

    ) q;


    -- ========================================================
    -- 7. NENHUM PROFISSIONAL COMPATÍVEL
    -- ========================================================

    IF jsonb_array_length(
        v_professionals
    ) = 0
    THEN

        RETURN jsonb_build_object(
            'ok', TRUE,
            'code', 'NO_ELIGIBLE_PROFESSIONAL',
            'count', 0,
            'slots', '[]'::JSONB
        );

    END IF;


    -- ========================================================
    -- 8. GERAR CANDIDATOS CRONOLOGICAMENTE
    --
    -- Em vez de gerar tudo e somente depois aplicar LIMIT,
    -- paramos assim que encontramos slots suficientes.
    -- ========================================================

    <<candidate_loop>>

    FOR v_candidate IN

        SELECT gs

        FROM generate_series(

            v_date_from::TIMESTAMP,

            (
                v_date_until
                + 1
            )::TIMESTAMP

            - make_interval(
                mins => v_slot_interval
            ),

            make_interval(
                mins => v_slot_interval
            )

        ) AS gs

    LOOP


        -- ====================================================
        -- 8.1 FILTRO: HORÁRIO MÍNIMO DESEJADO
        -- ====================================================

        IF p_time_from IS NOT NULL
           AND v_candidate::TIME <
                p_time_from
        THEN

            CONTINUE;

        END IF;


        -- ====================================================
        -- 8.2 FILTRO: HORÁRIO MÁXIMO DESEJADO
        -- ====================================================

        IF p_time_until IS NOT NULL
           AND v_candidate::TIME >=
                p_time_until
        THEN

            CONTINUE;

        END IF;


        -- Converter horário local da empresa para instante real.
        v_start_at :=
            v_candidate
            AT TIME ZONE v_timezone;


        -- ====================================================
        -- 8.3 ANTECEDÊNCIA MÍNIMA
        -- ====================================================

        IF v_start_at <
            NOW()
            + make_interval(
                mins => v_minimum_notice
            )
        THEN

            CONTINUE;

        END IF;


        -- ====================================================
        -- 9. TESTAR CADA PROFISSIONAL COMPATÍVEL
        -- ====================================================

        FOR v_prof IN

            SELECT *

            FROM jsonb_to_recordset(
                v_professionals
            )

            AS x(

                professional_id UUID,

                professional_name TEXT,

                display_order INTEGER,

                total_service_minutes INTEGER,

                total_price NUMERIC(10,2),

                currency TEXT,

                buffer_before_minutes INTEGER,

                buffer_after_minutes INTEGER

            )

            ORDER BY
                display_order,
                professional_name

        LOOP


            -- ================================================
            -- 9.1 CALCULAR FIM DO SERVIÇO
            -- ================================================

            v_end_at :=
                v_start_at
                + make_interval(
                    mins =>
                        v_prof.total_service_minutes
                );


            v_local_end :=
                v_candidate
                + make_interval(
                    mins =>
                        v_prof.total_service_minutes
                );


            -- ================================================
            -- 9.2 SE O CLIENTE INFORMOU HORÁRIO MÁXIMO,
            --     O SERVIÇO INTEIRO DEVE CABER NELE.
            --
            -- Ex.:
            -- deseja até 12:00
            -- serviço 60 min
            --
            -- 11:30 não será oferecido.
            -- ================================================

            IF p_time_until IS NOT NULL
               AND (
                    v_local_end::DATE
                        <> v_candidate::DATE

                    OR

                    v_local_end::TIME
                        > p_time_until
               )
            THEN

                CONTINUE;

            END IF;


            -- ================================================
            -- 9.3 CONSULTAR FONTE CENTRAL DE DISPONIBILIDADE
            -- ================================================

            v_availability :=
                core.check_slot_availability(

                    p_business_id,

                    v_prof.professional_id,

                    v_start_at,

                    v_end_at,

                    v_prof.buffer_before_minutes,

                    v_prof.buffer_after_minutes,

                    NULL

                );


            -- ================================================
            -- 9.4 SE DISPONÍVEL, ADICIONAR À RESPOSTA
            -- ================================================

            IF COALESCE(

                (
                    v_availability
                    ->> 'available'
                )::BOOLEAN,

                FALSE

            )
            THEN


                v_slots :=
                    v_slots
                    ||
                    jsonb_build_array(

                        jsonb_build_object(

                            'professional_id',
                                v_prof.professional_id,

                            'professional_name',
                                v_prof.professional_name,

                            'start_at',
                                v_start_at,

                            'end_at',
                                v_end_at,

                            'local_date',
                                v_candidate::DATE,

                            'local_start',
                                TO_CHAR(
                                    v_candidate,
                                    'HH24:MI'
                                ),

                            'local_end',
                                TO_CHAR(
                                    v_local_end,
                                    'HH24:MI'
                                ),

                            'total_service_minutes',
                                v_prof.total_service_minutes,

                            'total_price',
                                v_prof.total_price,

                            'currency',
                                v_prof.currency,

                            'buffer_before_minutes',
                                v_prof.buffer_before_minutes,

                            'buffer_after_minutes',
                                v_prof.buffer_after_minutes

                        )

                    );


                v_found :=
                    v_found + 1;


                -- ============================================
                -- JÁ TEMOS OPÇÕES SUFICIENTES
                -- ============================================

                IF v_found >= v_limit THEN

                    EXIT candidate_loop;

                END IF;


            END IF;


        END LOOP;

    END LOOP candidate_loop;


    -- ========================================================
    -- 10. RETORNO FINAL
    -- ========================================================

    RETURN jsonb_build_object(

        'ok',
            TRUE,

        'code',
            CASE
                WHEN v_found > 0
                    THEN 'AVAILABLE_SLOTS'
                ELSE 'NO_SLOTS'
            END,

        'count',
            v_found,

        'timezone',
            v_timezone,

        'date_from',
            v_date_from,

        'date_until',
            v_date_until,

        'slots',
            v_slots

    );

END;

$$;