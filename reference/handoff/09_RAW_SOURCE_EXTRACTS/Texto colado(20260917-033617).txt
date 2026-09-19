-- ============================================================
-- ML AUTOMAÇÕES
-- Migration: 019_slot_offer_transaction_functions
--
-- Finalidade:
--
-- 1. Endurecer integridade tenant-safe de slot_offer_options.
--
-- 2. create_slot_offer()
--    - bloqueia a conversa
--    - gera horários
--    - invalida oferta anterior
--    - salva a nova oferta
--    - salva opções 1...N
--
-- 3. select_slot_offer_option()
--    - recebe "1", "2", "3"...
--    - encontra a oferta ACTIVE
--    - valida expiração
--    - recupera exatamente o slot oferecido
--    - chama create_appointment_hold()
--    - marca a oferta como SELECTED se conseguir
--
-- 4. expire_stale_slot_offers()
--    - limpeza concorrente de ofertas vencidas
-- ============================================================


-- ============================================================
-- 1. HARDENING TENANT-SAFE
-- ============================================================

DO $$
BEGIN

    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conrelid = 'core.slot_offers'::regclass
          AND conname = 'uq_slot_offers_business_id_id'
    )
    THEN

        ALTER TABLE core.slot_offers

        ADD CONSTRAINT
            uq_slot_offers_business_id_id

        UNIQUE (
            business_id,
            id
        );

    END IF;

END
$$;


-- A FK criada na 018 apontava somente por slot_offer_id.
-- Vamos torná-la tenant-safe.

ALTER TABLE core.slot_offer_options

DROP CONSTRAINT IF EXISTS
    fk_slot_option_offer;


ALTER TABLE core.slot_offer_options

ADD CONSTRAINT fk_slot_option_offer

FOREIGN KEY (
    business_id,
    slot_offer_id
)

REFERENCES core.slot_offers (
    business_id,
    id
)

ON DELETE CASCADE;


-- ============================================================
-- 2. CRIAR OFERTA DE HORÁRIOS
-- ============================================================

CREATE OR REPLACE FUNCTION core.create_slot_offer(

    p_business_id UUID,

    p_conversation_id UUID,

    p_service_ids UUID[],

    p_date_from DATE,

    p_date_until DATE,

    p_professional_id UUID DEFAULT NULL,

    p_time_from TIME DEFAULT NULL,

    p_time_until TIME DEFAULT NULL,

    p_limit INTEGER DEFAULT NULL,

    p_expires_in_minutes INTEGER DEFAULT 10

)
RETURNS JSONB

LANGUAGE plpgsql

AS $$

DECLARE

    v_customer_id UUID;

    v_conversation_status VARCHAR(30);

    v_generation JSONB;

    v_generation_ok BOOLEAN;

    v_generation_code TEXT;

    v_option_count INTEGER;

    v_inserted_count INTEGER;

    v_offer_id UUID;

    v_offer_status VARCHAR(30);

    v_expires_at TIMESTAMPTZ;

BEGIN


    -- ========================================================
    -- 2.1 VALIDAR TTL DA OFERTA
    -- ========================================================

    IF p_expires_in_minutes IS NULL
       OR p_expires_in_minutes < 1
       OR p_expires_in_minutes > 120
    THEN

        RETURN jsonb_build_object(
            'ok', FALSE,
            'code', 'INVALID_OFFER_EXPIRATION'
        );

    END IF;


    -- ========================================================
    -- 2.2 BLOQUEAR A CONVERSA
    --
    -- Isso serializa duas execuções simultâneas da mesma
    -- conversa.
    --
    -- Ex.:
    -- A: "quero de manhã"
    -- B: "na verdade de tarde"
    --
    -- Uma termina antes da outra modificar a oferta ativa.
    -- ========================================================

    SELECT
        c.customer_id,
        c.status

    INTO
        v_customer_id,
        v_conversation_status

    FROM core.conversations c

    WHERE c.business_id = p_business_id
      AND c.id = p_conversation_id

    FOR UPDATE;


    IF NOT FOUND THEN

        RETURN jsonb_build_object(
            'ok', FALSE,
            'code', 'CONVERSATION_NOT_FOUND'
        );

    END IF;


    IF v_conversation_status <> 'OPEN' THEN

        RETURN jsonb_build_object(
            'ok', FALSE,
            'code', 'CONVERSATION_NOT_OPEN',
            'conversation_status',
            v_conversation_status
        );

    END IF;


    -- ========================================================
    -- 2.3 GERAR HORÁRIOS
    -- ========================================================

    v_generation :=
        core.get_available_slots(

            p_business_id,

            p_service_ids,

            p_date_from,

            p_date_until,

            p_professional_id,

            p_time_from,

            p_time_until,

            p_limit
        );


    v_generation_ok :=
        COALESCE(
            (v_generation ->> 'ok')::BOOLEAN,
            FALSE
        );


    v_generation_code :=
        COALESCE(
            v_generation ->> 'code',
            'UNKNOWN'
        );


    IF NOT v_generation_ok THEN

        RETURN jsonb_build_object(
            'ok', FALSE,
            'code', 'SLOT_GENERATION_FAILED',
            'generation',
            v_generation
        );

    END IF;


    v_option_count :=
        COALESCE(
            (v_generation ->> 'count')::INTEGER,
            0
        );


    -- ========================================================
    -- 2.4 INVALIDAR OFERTA ACTIVE ANTERIOR
    --
    -- Como a conversa está bloqueada, não temos corrida aqui.
    -- ========================================================

    UPDATE core.slot_offers

    SET status = 'SUPERSEDED'

    WHERE business_id = p_business_id

      AND conversation_id =
            p_conversation_id

      AND status = 'ACTIVE';


    -- ========================================================
    -- 2.5 DEFINIR EXPIRAÇÃO
    -- ========================================================

    v_expires_at :=
        NOW()
        + make_interval(
            mins => p_expires_in_minutes
        );


    -- ========================================================
    -- 2.6 NENHUM SLOT DISPONÍVEL
    --
    -- Também persistimos isso.
    --
    -- Assim conseguimos auditar:
    -- "o bot pesquisou, mas não havia vaga".
    -- ========================================================

    IF v_option_count = 0 THEN

        INSERT INTO core.slot_offers (

            business_id,

            conversation_id,

            customer_id,

            requested_service_ids,

            requested_professional_id,

            date_from,

            date_until,

            time_from,

            time_until,

            status,

            expires_at,

            option_count,

            metadata

        )

        VALUES (

            p_business_id,

            p_conversation_id,

            v_customer_id,

            p_service_ids,

            p_professional_id,

            p_date_from,

            p_date_until,

            p_time_from,

            p_time_until,

            'EMPTY',

            v_expires_at,

            0,

            jsonb_build_object(

                'generation_code',
                    v_generation_code,

                'timezone',
                    v_generation ->> 'timezone'

            )

        )

        RETURNING id
        INTO v_offer_id;


        RETURN jsonb_build_object(

            'ok', TRUE,

            'code', 'NO_SLOTS',

            'slot_offer_id',
                v_offer_id,

            'conversation_id',
                p_conversation_id,

            'count',
                0,

            'slots',
                '[]'::JSONB

        );

    END IF;


    -- ========================================================
    -- 2.7 CRIAR OFERTA ACTIVE
    -- ========================================================

    INSERT INTO core.slot_offers (

        business_id,

        conversation_id,

        customer_id,

        requested_service_ids,

        requested_professional_id,

        date_from,

        date_until,

        time_from,

        time_until,

        status,

        expires_at,

        option_count,

        metadata

    )

    VALUES (

        p_business_id,

        p_conversation_id,

        v_customer_id,

        p_service_ids,

        p_professional_id,

        p_date_from,

        p_date_until,

        p_time_from,

        p_time_until,

        'ACTIVE',

        v_expires_at,

        v_option_count,

        jsonb_build_object(

            'generation_code',
                v_generation_code,

            'timezone',
                v_generation ->> 'timezone'

        )

    )

    RETURNING id, status

    INTO
        v_offer_id,
        v_offer_status;


    -- ========================================================
    -- 2.8 PERSISTIR OPÇÕES
    --
    -- WITH ORDINALITY garante:
    --
    -- 1 = primeiro slot
    -- 2 = segundo slot
    -- 3 = terceiro slot
    -- etc.
    -- ========================================================

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

        v_offer_id,

        x.ordinality::INTEGER,

        (x.slot ->> 'professional_id')::UUID,

        (x.slot ->> 'start_at')::TIMESTAMPTZ,

        (x.slot ->> 'end_at')::TIMESTAMPTZ,

        (x.slot ->> 'total_service_minutes')::INTEGER,

        (x.slot ->> 'total_price')::NUMERIC(10,2),

        COALESCE(
            x.slot ->> 'currency',
            'BRL'
        ),

        COALESCE(
            (
                x.slot
                ->> 'buffer_before_minutes'
            )::INTEGER,
            0
        ),

        COALESCE(
            (
                x.slot
                ->> 'buffer_after_minutes'
            )::INTEGER,
            0
        ),

        x.slot ->> 'professional_name',

        x.slot

    FROM jsonb_array_elements(
        v_generation -> 'slots'
    )

    WITH ORDINALITY
    AS x(slot, ordinality);


    GET DIAGNOSTICS
        v_inserted_count = ROW_COUNT;


    -- ========================================================
    -- 2.9 DEFESA DE CONSISTÊNCIA
    --
    -- Se o gerador disser que devolveu 5 slots
    -- mas apenas 4 forem persistidos, abortamos.
    --
    -- Como estamos dentro da mesma transação, tudo volta atrás.
    -- ========================================================

    IF v_inserted_count <> v_option_count THEN

        RAISE EXCEPTION
            'SLOT_OFFER_OPTION_COUNT_MISMATCH: expected %, inserted %',
            v_option_count,
            v_inserted_count;

    END IF;


    -- ========================================================
    -- 2.10 RETORNO
    -- ========================================================

    RETURN jsonb_build_object(

        'ok', TRUE,

        'code', 'SLOT_OFFER_CREATED',

        'slot_offer_id',
            v_offer_id,

        'conversation_id',
            p_conversation_id,

        'status',
            v_offer_status,

        'expires_at',
            v_expires_at,

        'count',
            v_option_count,

        'timezone',
            v_generation ->> 'timezone',

        'slots',
            v_generation -> 'slots'

    );

END;

$$;


-- ============================================================
-- 3. SELECIONAR UMA OPÇÃO DA OFERTA
-- ============================================================

CREATE OR REPLACE FUNCTION core.select_slot_offer_option(

    p_business_id UUID,

    p_conversation_id UUID,

    p_option_number INTEGER,

    p_source_channel VARCHAR DEFAULT NULL,

    p_source_provider VARCHAR DEFAULT NULL

)
RETURNS JSONB

LANGUAGE plpgsql

AS $$

DECLARE

    v_customer_id UUID;

    v_conversation_status VARCHAR(30);

    v_offer core.slot_offers%ROWTYPE;

    v_option core.slot_offer_options%ROWTYPE;

    v_hold_result JSONB;

    v_hold_ok BOOLEAN;

BEGIN


    -- ========================================================
    -- 3.1 VALIDAR OPÇÃO
    -- ========================================================

    IF p_option_number IS NULL
       OR p_option_number < 1
       OR p_option_number > 50
    THEN

        RETURN jsonb_build_object(
            'ok', FALSE,
            'code', 'INVALID_OPTION_NUMBER'
        );

    END IF;


    -- ========================================================
    -- 3.2 BLOQUEAR CONVERSA
    --
    -- Impede duas respostas concorrentes de selecionarem
    -- a mesma oferta simultaneamente.
    -- ========================================================

    SELECT
        c.customer_id,
        c.status

    INTO
        v_customer_id,
        v_conversation_status

    FROM core.conversations c

    WHERE c.business_id = p_business_id
      AND c.id = p_conversation_id

    FOR UPDATE;


    IF NOT FOUND THEN

        RETURN jsonb_build_object(
            'ok', FALSE,
            'code', 'CONVERSATION_NOT_FOUND'
        );

    END IF;


    IF v_conversation_status <> 'OPEN' THEN

        RETURN jsonb_build_object(
            'ok', FALSE,
            'code', 'CONVERSATION_NOT_OPEN',
            'conversation_status',
            v_conversation_status
        );

    END IF;


    -- ========================================================
    -- 3.3 BUSCAR OFERTA ACTIVE
    -- ========================================================

    SELECT so.*

    INTO v_offer

    FROM core.slot_offers so

    WHERE so.business_id = p_business_id

      AND so.conversation_id =
            p_conversation_id

      AND so.status = 'ACTIVE'

    ORDER BY so.created_at DESC

    LIMIT 1

    FOR UPDATE;


    IF NOT FOUND THEN

        RETURN jsonb_build_object(
            'ok', FALSE,
            'code', 'NO_ACTIVE_SLOT_OFFER'
        );

    END IF;


    -- ========================================================
    -- 3.4 VALIDAR EXPIRAÇÃO
    -- ========================================================

    IF v_offer.expires_at <= NOW() THEN

        UPDATE core.slot_offers

        SET status = 'EXPIRED'

        WHERE business_id =
                p_business_id

          AND id =
                v_offer.id;


        RETURN jsonb_build_object(

            'ok', FALSE,

            'code', 'SLOT_OFFER_EXPIRED',

            'slot_offer_id',
                v_offer.id

        );

    END IF;


    -- ========================================================
    -- 3.5 BUSCAR OPÇÃO EXATA
    -- ========================================================

    SELECT soo.*

    INTO v_option

    FROM core.slot_offer_options soo

    WHERE soo.business_id =
            p_business_id

      AND soo.slot_offer_id =
            v_offer.id

      AND soo.option_number =
            p_option_number;


    IF NOT FOUND THEN

        RETURN jsonb_build_object(

            'ok', FALSE,

            'code', 'OPTION_NOT_FOUND',

            'slot_offer_id',
                v_offer.id,

            'requested_option',
                p_option_number,

            'option_count',
                v_offer.option_count

        );

    END IF;


    -- ========================================================
    -- 3.6 REVALIDAR E CRIAR HOLD
    --
    -- NÃO confiamos cegamente no slot salvo.
    --
    -- create_appointment_hold() verifica tudo novamente:
    -- - expediente
    -- - profissional
    -- - serviços
    -- - conflito
    -- - buffers
    -- - overrides
    -- - concorrência
    -- ========================================================

    v_hold_result :=
        core.create_appointment_hold(

            p_business_id,

            v_customer_id,

            v_option.professional_id,

            v_option.start_at,

            v_offer.requested_service_ids,

            p_source_channel,

            p_source_provider

        );


    v_hold_ok :=
        COALESCE(
            (v_hold_result ->> 'ok')::BOOLEAN,
            FALSE
        );


    -- ========================================================
    -- 3.7 SLOT NÃO ESTÁ MAIS DISPONÍVEL
    --
    -- A oferta continua ACTIVE por enquanto.
    --
    -- O n8n poderá:
    -- - sugerir outra opção ainda válida
    -- - ou criar uma nova oferta
    -- ========================================================

    IF NOT v_hold_ok THEN

        RETURN jsonb_build_object(

            'ok', FALSE,

            'code', 'SLOT_SELECTION_FAILED',

            'reason',
                v_hold_result ->> 'code',

            'slot_offer_id',
                v_offer.id,

            'option_number',
                p_option_number,

            'hold_result',
                v_hold_result

        );

    END IF;


    -- ========================================================
    -- 3.8 MARCAR OFERTA COMO SELECIONADA
    -- ========================================================

    UPDATE core.slot_offers

    SET
        status = 'SELECTED',

        selected_option_number =
            p_option_number,

        selected_at =
            NOW()

    WHERE business_id =
            p_business_id

      AND id =
            v_offer.id;


    -- ========================================================
    -- 3.9 RETORNO FINAL
    -- ========================================================

    RETURN jsonb_build_object(

        'ok', TRUE,

        'code', 'SLOT_SELECTED',

        'slot_offer_id',
            v_offer.id,

        'option_number',
            p_option_number,

        'professional_id',
            v_option.professional_id,

        'start_at',
            v_option.start_at,

        'end_at',
            v_option.end_at,

        'hold',
            v_hold_result

    );

END;

$$;


-- ============================================================
-- 4. EXPIRAR OFERTAS VENCIDAS
-- ============================================================

CREATE OR REPLACE FUNCTION core.expire_stale_slot_offers(

    p_limit INTEGER DEFAULT 500

)
RETURNS INTEGER

LANGUAGE plpgsql

AS $$

DECLARE

    v_limit INTEGER;

    v_count INTEGER;

BEGIN


    v_limit :=
        LEAST(
            GREATEST(
                COALESCE(
                    p_limit,
                    500
                ),
                1
            ),
            5000
        );


    WITH targets AS (

        SELECT so.id

        FROM core.slot_offers so

        WHERE so.status = 'ACTIVE'

          AND so.expires_at <= NOW()

        ORDER BY so.expires_at

        FOR UPDATE SKIP LOCKED

        LIMIT v_limit

    ),

    updated AS (

        UPDATE core.slot_offers so

        SET status = 'EXPIRED'

        FROM targets t

        WHERE so.id = t.id

        RETURNING so.id

    )

    SELECT COUNT(*)::INTEGER

    INTO v_count

    FROM updated;


    RETURN COALESCE(
        v_count,
        0
    );

END;

$$;