-- ============================================================
-- 029_assistant_turn_cleanup
--
-- Limpeza automática por empresa antes de montar o contexto
-- usado pela IA.
--
-- Resolve:
-- - HOLD vencido ainda aparecendo no contexto;
-- - slot_offer ACTIVE já vencida;
-- - bloqueio indevido de horários por HOLD expirado.
-- ============================================================


-- ============================================================
-- 1. EXPIRAR HOLDS VENCIDOS DA EMPRESA
-- ============================================================

CREATE OR REPLACE FUNCTION core.expire_stale_holds_for_business(
    p_business_id UUID,
    p_limit INTEGER DEFAULT 100
)
RETURNS INTEGER
LANGUAGE plpgsql
VOLATILE
AS $$
DECLARE
    v_record RECORD;
    v_count INTEGER := 0;
    v_limit INTEGER;
BEGIN

    v_limit :=
        LEAST(
            GREATEST(
                COALESCE(p_limit, 100),
                1
            ),
            1000
        );


    FOR v_record IN

        SELECT
            a.id,
            a.business_id

        FROM core.appointments a

        WHERE a.business_id = p_business_id
          AND a.status = 'HOLD'
          AND a.hold_expires_at <= NOW()

        ORDER BY a.hold_expires_at

        FOR UPDATE SKIP LOCKED

        LIMIT v_limit

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


            -- Mesma regra da função global existente:
            -- se o HOLD estiver ligado a waitlist, expira a oferta.
            UPDATE core.waitlist_offers

            SET
                status = 'EXPIRED',
                responded_at = NOW()

            WHERE business_id = v_record.business_id
              AND hold_appointment_id = v_record.id
              AND status IN (
                    'PENDING',
                    'SENT'
              );


            v_count := v_count + 1;

        END IF;

    END LOOP;


    RETURN v_count;

END;
$$;



-- ============================================================
-- 2. EXPIRAR SLOT OFFERS VENCIDAS DA EMPRESA
-- ============================================================

CREATE OR REPLACE FUNCTION core.expire_stale_slot_offers_for_business(
    p_business_id UUID,
    p_limit INTEGER DEFAULT 100
)
RETURNS INTEGER
LANGUAGE plpgsql
VOLATILE
AS $$
DECLARE
    v_limit INTEGER;
    v_count INTEGER;
BEGIN

    v_limit :=
        LEAST(
            GREATEST(
                COALESCE(p_limit, 100),
                1
            ),
            1000
        );


    WITH targets AS (

        SELECT so.id

        FROM core.slot_offers so

        WHERE so.business_id = p_business_id
          AND so.status = 'ACTIVE'
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


    RETURN COALESCE(v_count, 0);

END;
$$;



-- ============================================================
-- 3. ATUALIZAR PREPARE_ASSISTANT_TURN
--
-- Ordem:
--
-- resolver cliente/conversa
-- → limpar estados vencidos
-- → recarregar contexto limpo
-- → registrar inbound
-- → carregar histórico
-- ============================================================

CREATE OR REPLACE FUNCTION core.prepare_assistant_turn(
    p_business_code TEXT,
    p_channel_type TEXT,
    p_provider TEXT,
    p_external_user_id TEXT,

    p_idempotency_key TEXT,
    p_external_message_id TEXT,

    p_message_type TEXT,
    p_text_content TEXT,

    p_raw_payload JSONB DEFAULT '{}'::JSONB,

    p_provider_timestamp TIMESTAMPTZ DEFAULT NULL,

    p_recent_messages_limit INTEGER DEFAULT 12
)
RETURNS JSONB
LANGUAGE plpgsql
VOLATILE
AS $$
DECLARE

    v_context JSONB;

    v_business_id UUID;
    v_conversation_id UUID;
    v_customer_id UUID;
    v_customer_channel_id UUID;

    v_inbound JSONB;

    v_recent_messages JSONB;

    v_expired_holds INTEGER := 0;
    v_expired_offers INTEGER := 0;

BEGIN

    -- ========================================================
    -- 1. RESOLVER EMPRESA / CLIENTE / CONVERSA
    -- ========================================================

    v_context :=
        core.prepare_assistant_context(
            p_business_code,
            p_channel_type,
            p_provider,
            p_external_user_id
        );


    IF NOT COALESCE(
        (v_context ->> 'ok')::BOOLEAN,
        FALSE
    )
    THEN

        RETURN JSONB_BUILD_OBJECT(

            'ok',
                FALSE,

            'code',
                COALESCE(
                    v_context ->> 'code',
                    'ASSISTANT_CONTEXT_FAILED'
                ),

            'context',
                v_context
        );

    END IF;


    -- ========================================================
    -- 2. EXTRAIR IDENTIDADES
    -- ========================================================

    v_business_id :=
        NULLIF(
            v_context #>> '{business,id}',
            ''
        )::UUID;


    v_conversation_id :=
        NULLIF(
            v_context #>> '{conversation,id}',
            ''
        )::UUID;


    v_customer_id :=
        NULLIF(
            v_context #>> '{customer,id}',
            ''
        )::UUID;


    v_customer_channel_id :=
        NULLIF(
            v_context #>> '{customer,channel_id}',
            ''
        )::UUID;


    IF v_business_id IS NULL
       OR v_conversation_id IS NULL
       OR v_customer_id IS NULL
       OR v_customer_channel_id IS NULL
    THEN

        RETURN JSONB_BUILD_OBJECT(

            'ok',
                FALSE,

            'code',
                'INCOMPLETE_ASSISTANT_CONTEXT',

            'context',
                v_context
        );

    END IF;


    -- ========================================================
    -- 3. LIMPEZA AUTOMÁTICA DA EMPRESA
    -- ========================================================

    v_expired_holds :=
        core.expire_stale_holds_for_business(
            v_business_id,
            100
        );


    v_expired_offers :=
        core.expire_stale_slot_offers_for_business(
            v_business_id,
            100
        );


    -- ========================================================
    -- 4. RECARREGAR CONTEXTO APÓS LIMPEZA
    --
    -- Agora a IA não recebe HOLD ou oferta ACTIVE vencidos.
    -- ========================================================

    v_context :=
        core.get_assistant_context(
            p_business_code,
            p_channel_type,
            p_provider,
            p_external_user_id
        );


    IF NOT COALESCE(
        (v_context ->> 'ok')::BOOLEAN,
        FALSE
    )
    THEN

        RETURN JSONB_BUILD_OBJECT(

            'ok',
                FALSE,

            'code',
                'ASSISTANT_CONTEXT_RELOAD_FAILED',

            'context',
                v_context
        );

    END IF;


    -- ========================================================
    -- 5. REGISTRAR INBOUND
    -- ========================================================

    v_inbound :=
        core.register_inbound_message(

            v_business_id,

            v_conversation_id,

            v_customer_id,

            v_customer_channel_id,

            p_channel_type,

            p_provider,

            p_idempotency_key,

            p_external_message_id,

            UPPER(
                COALESCE(
                    NULLIF(
                        TRIM(p_message_type),
                        ''
                    ),
                    'TEXT'
                )
            ),

            p_text_content,

            COALESCE(
                p_raw_payload,
                '{}'::JSONB
            ),

            JSONB_BUILD_OBJECT(
                'normalized_text',
                p_text_content
            ),

            p_provider_timestamp
        );


    IF NOT COALESCE(
        (v_inbound ->> 'ok')::BOOLEAN,
        FALSE
    )
    THEN

        RETURN JSONB_BUILD_OBJECT(

            'ok',
                FALSE,

            'code',
                COALESCE(
                    v_inbound ->> 'code',
                    'INBOUND_REGISTRATION_FAILED'
                ),

            'turn',
                v_inbound,

            'context',
                v_context
        );

    END IF;


    -- ========================================================
    -- 6. HISTÓRICO RECENTE
    -- ========================================================

    v_recent_messages :=
        core.get_recent_conversation_messages(
            v_business_id,
            v_conversation_id,
            p_recent_messages_limit
        );


    -- ========================================================
    -- 7. INJETAR HISTÓRICO
    -- ========================================================

    v_context :=
        JSONB_SET(
            v_context,
            '{recent_messages}',
            COALESCE(
                v_recent_messages,
                '[]'::JSONB
            ),
            TRUE
        );


    -- ========================================================
    -- 8. INJETAR METADADOS DO TURNO
    -- ========================================================

    v_context :=
        JSONB_SET(
            v_context,
            '{turn}',
            v_inbound,
            TRUE
        );


    -- ========================================================
    -- 9. RETORNO
    -- ========================================================

    RETURN v_context;

END;
$$;