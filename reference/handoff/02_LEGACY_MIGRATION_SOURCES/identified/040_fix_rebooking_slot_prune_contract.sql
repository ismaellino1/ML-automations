-- ============================================================
-- 040_fix_rebooking_slot_prune_contract
--
-- Corrige o contrato entre:
--   core.create_slot_offer(...)
-- e:
--   core.prune_cancelled_rebooking_slot_offer(...)
--
-- create_slot_offer retorna:
--   count
--   slots
--
-- A versão 039 esperava incorretamente:
--   option_count
--   options
--
-- Esta versão:
--   1. filtra result.slots
--   2. exclui somente o intervalo exato do appointment cancelado
--   3. limita a quantidade apresentada
--   4. recria slot_offer_options com numeração 1..N
--   5. mantém banco e JSON coerentes
--   6. não bloqueia o horário cancelado para outros clientes
-- ============================================================

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
    v_result JSONB :=
        COALESCE(
            p_slot_offer_result,
            '{}'::JSONB
        );

    v_slot_offer_id UUID;

    v_filtered_slots JSONB :=
        '[]'::JSONB;

    v_slot_count INTEGER := 0;

BEGIN

    -- ========================================================
    -- A CRIAÇÃO DA OFERTA PRECISA TER FUNCIONADO
    -- ========================================================

    IF COALESCE(
        (v_result ->> 'ok')::BOOLEAN,
        FALSE
    ) IS NOT TRUE
    THEN
        RETURN v_result;
    END IF;


    -- ========================================================
    -- IDENTIFICAR A OFERTA
    -- ========================================================

    v_slot_offer_id :=
        NULLIF(
            v_result ->> 'slot_offer_id',
            ''
        )::UUID;


    IF v_slot_offer_id IS NULL
    THEN

        RETURN
            v_result
            || JSONB_BUILD_OBJECT(
                'ok',
                    FALSE,

                'code',
                    'REBOOKING_SLOT_OFFER_ID_MISSING'
            );

    END IF;


    -- ========================================================
    -- SEGURANÇA MULTI-TENANT
    -- ========================================================

    IF NOT EXISTS (

        SELECT 1

        FROM core.slot_offers so

        WHERE so.id =
                  v_slot_offer_id

          AND so.business_id =
                  p_business_id

    )
    THEN

        RETURN
            v_result
            || JSONB_BUILD_OBJECT(
                'ok',
                    FALSE,

                'code',
                    'REBOOKING_SLOT_OFFER_NOT_OWNED'
            );

    END IF;


    -- ========================================================
    -- FILTRAR OS SLOTS
    --
    -- IMPORTANTE:
    --
    -- O contrato REAL de create_slot_offer usa:
    --
    --     slots
    --     count
    --
    -- Não:
    --
    --     options
    --     option_count
    --
    -- Remove SOMENTE quando start_at E end_at forem exatamente
    -- iguais ao appointment cancelado.
    --
    -- Depois limita à quantidade normal apresentada ao cliente.
    -- ========================================================

    SELECT
        COALESCE(
            JSONB_AGG(
                q.slot_json
                ORDER BY q.ordinality
            ),
            '[]'::JSONB
        )

    INTO
        v_filtered_slots

    FROM (

        SELECT
            e.slot_json,
            e.ordinality

        FROM JSONB_ARRAY_ELEMENTS(
                 COALESCE(
                     v_result -> 'slots',
                     '[]'::JSONB
                 )
             )
             WITH ORDINALITY
             AS e(
                 slot_json,
                 ordinality
             )

        WHERE NOT (

            NULLIF(
                e.slot_json ->> 'start_at',
                ''
            )::TIMESTAMPTZ
                IS NOT DISTINCT FROM
                p_excluded_start

            AND

            NULLIF(
                e.slot_json ->> 'end_at',
                ''
            )::TIMESTAMPTZ
                IS NOT DISTINCT FROM
                p_excluded_end

        )

        ORDER BY
            e.ordinality

        LIMIT
            GREATEST(
                COALESCE(
                    p_max_options,
                    5
                ),
                1
            )

    ) q;


    v_slot_count :=
        JSONB_ARRAY_LENGTH(
            v_filtered_slots
        );


    -- ========================================================
    -- NENHUMA ALTERNATIVA RESTOU
    -- ========================================================

    IF v_slot_count = 0
    THEN

        DELETE FROM core.slot_offer_options soo

        WHERE soo.business_id =
                  p_business_id

          AND soo.slot_offer_id =
                  v_slot_offer_id;


        DELETE FROM core.slot_offers so

        WHERE so.id =
                  v_slot_offer_id

          AND so.business_id =
                  p_business_id;


        v_result :=
            JSONB_SET(
                v_result,
                '{slots}',
                '[]'::JSONB,
                TRUE
            );


        v_result :=
            JSONB_SET(
                v_result,
                '{count}',
                TO_JSONB(0),
                TRUE
            );


        -- Remove campos introduzidos incorretamente pela 039,
        -- caso existam no payload recebido.
        v_result :=
            (
                v_result
                - 'options'
            )
            - 'option_count';


        RETURN

            v_result

            || JSONB_BUILD_OBJECT(

                'ok',
                    FALSE,

                'code',
                    'NO_ALTERNATIVE_SLOTS_AFTER_CANCELLED_INTERVAL_EXCLUSION',

                'excluded_source_appointment_id',
                    p_source_appointment_id,

                'excluded_start_at',
                    p_excluded_start,

                'excluded_end_at',
                    p_excluded_end

            );

    END IF;


    -- ========================================================
    -- RECONSTRUIR AS OPÇÕES PERSISTIDAS
    --
    -- Não mantemos os option_numbers antigos porque, após
    -- remover um slot do meio da lista, poderíamos ficar com:
    --
    --     1, 2, 4, 5, 6
    --
    -- enquanto o cliente enxerga:
    --
    --     1, 2, 3, 4, 5
    --
    -- Portanto reconstruímos 1..N.
    -- ========================================================

    DELETE FROM core.slot_offer_options soo

    WHERE soo.business_id =
              p_business_id

      AND soo.slot_offer_id =
              v_slot_offer_id;


    INSERT INTO core.slot_offer_options (

        business_id,

        slot_offer_id,

        option_number,

        professional_id,

        start_at,

        end_at,

        total_service_minutes,

        total_price,

        currency,

        buffer_before_minutes,

        buffer_after_minutes,

        professional_name_snapshot,

        slot_snapshot

    )

    SELECT

        p_business_id,

        v_slot_offer_id,

        e.ordinality::INTEGER,

        NULLIF(
            e.slot_json ->> 'professional_id',
            ''
        )::UUID,

        NULLIF(
            e.slot_json ->> 'start_at',
            ''
        )::TIMESTAMPTZ,

        NULLIF(
            e.slot_json ->> 'end_at',
            ''
        )::TIMESTAMPTZ,

        COALESCE(
            NULLIF(
                e.slot_json ->> 'total_service_minutes',
                ''
            )::INTEGER,
            0
        ),

        NULLIF(
            e.slot_json ->> 'total_price',
            ''
        )::NUMERIC,

        COALESCE(
            NULLIF(
                e.slot_json ->> 'currency',
                ''
            ),
            'BRL'
        ),

        COALESCE(
            NULLIF(
                e.slot_json ->> 'buffer_before_minutes',
                ''
            )::INTEGER,
            0
        ),

        COALESCE(
            NULLIF(
                e.slot_json ->> 'buffer_after_minutes',
                ''
            )::INTEGER,
            0
        ),

        NULLIF(
            e.slot_json ->> 'professional_name',
            ''
        ),

        JSONB_SET(
            e.slot_json,
            '{option_number}',
            TO_JSONB(
                e.ordinality::INTEGER
            ),
            TRUE
        )

    FROM JSONB_ARRAY_ELEMENTS(
             v_filtered_slots
         )
         WITH ORDINALITY
         AS e(
             slot_json,
             ordinality
         )

    ORDER BY
        e.ordinality;


    -- ========================================================
    -- ATUALIZAR A OFERTA
    -- ========================================================

    UPDATE core.slot_offers so

    SET

        option_count =
            v_slot_count,

        metadata =
            COALESCE(
                so.metadata,
                '{}'::JSONB
            )

            || JSONB_BUILD_OBJECT(

                'rebooking_source_appointment_id',
                    p_source_appointment_id,

                'excluded_cancelled_interval',
                    JSONB_BUILD_OBJECT(
                        'start_at',
                            p_excluded_start,

                        'end_at',
                            p_excluded_end
                    )

            ),

        updated_at =
            NOW()

    WHERE so.id =
              v_slot_offer_id

      AND so.business_id =
              p_business_id;


    -- ========================================================
    -- ATUALIZAR O CONTRATO JSON REAL
    -- ========================================================

    v_result :=
        JSONB_SET(
            v_result,
            '{slots}',
            v_filtered_slots,
            TRUE
        );


    v_result :=
        JSONB_SET(
            v_result,
            '{count}',
            TO_JSONB(
                v_slot_count
            ),
            TRUE
        );


    -- Limpa os campos errados que a 039 introduziu.
    v_result :=
        (
            v_result
            - 'options'
        )
        - 'option_count';


    -- ========================================================
    -- RETORNO
    -- ========================================================

    RETURN

        v_result

        || JSONB_BUILD_OBJECT(

            'excluded_source_appointment_id',
                p_source_appointment_id,

            'excluded_start_at',
                p_excluded_start,

            'excluded_end_at',
                p_excluded_end

        );

END;
$function$;