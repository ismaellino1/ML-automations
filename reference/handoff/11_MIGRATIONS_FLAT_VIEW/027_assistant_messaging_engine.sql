-- ============================================================
-- 027_assistant_messaging_engine
--
-- Camada universal de mensagens da V3.
--
-- Responsabilidades:
-- - registrar INBOUND com idempotência;
-- - impedir processamento duplicado;
-- - marcar processamento da mensagem;
-- - registrar OUTBOUND como QUEUED;
-- - vincular external_message_id do provedor;
-- - registrar callbacks SENT / DELIVERED / READ / FAILED;
-- - suportar callback chegando antes do bind;
-- - fornecer histórico recente para contexto da IA.
-- ============================================================



-- ============================================================
-- 1. EVENTOS DE ENTREGA DO PROVEDOR
--
-- Guardamos callbacks separadamente.
--
-- Isso resolve a corrida:
--
-- Meta callback
-- ↓
-- ainda não fizemos bind do wamid
-- ↓
-- evento fica pendente
-- ↓
-- bind acontece
-- ↓
-- eventos pendentes são reaplicados
-- ============================================================

CREATE TABLE IF NOT EXISTS core.message_delivery_events (

    id UUID PRIMARY KEY
        DEFAULT gen_random_uuid(),

    business_id UUID NOT NULL
        REFERENCES core.businesses(id)
        ON DELETE CASCADE,

    provider VARCHAR(50) NOT NULL,

    external_message_id TEXT NOT NULL,

    delivery_status VARCHAR(30) NOT NULL,

    provider_timestamp TIMESTAMPTZ,

    error_detail TEXT,

    raw_payload JSONB NOT NULL
        DEFAULT '{}'::JSONB,

    event_key TEXT NOT NULL UNIQUE,

    applied_message_id UUID
        REFERENCES core.messages(id)
        ON DELETE CASCADE,

    applied_at TIMESTAMPTZ,

    created_at TIMESTAMPTZ NOT NULL
        DEFAULT NOW(),

    CONSTRAINT message_delivery_events_status_check
        CHECK (
            delivery_status IN (
                'SENT',
                'DELIVERED',
                'READ',
                'FAILED'
            )
        )
);


CREATE INDEX IF NOT EXISTS
idx_message_delivery_events_pending

ON core.message_delivery_events (
    business_id,
    provider,
    external_message_id,
    created_at
)

WHERE applied_at IS NULL;



-- ============================================================
-- 2. REGISTRAR MENSAGEM INBOUND
-- ============================================================

CREATE OR REPLACE FUNCTION core.register_inbound_message(

    p_business_id UUID,

    p_conversation_id UUID,

    p_customer_id UUID,

    p_customer_channel_id UUID,

    p_channel_type TEXT,

    p_provider TEXT,

    p_idempotency_key TEXT,

    p_external_message_id TEXT DEFAULT NULL,

    p_message_type TEXT DEFAULT 'TEXT',

    p_text_content TEXT DEFAULT NULL,

    p_raw_payload JSONB DEFAULT '{}'::JSONB,

    p_canonical_payload JSONB DEFAULT '{}'::JSONB,

    p_provider_timestamp TIMESTAMPTZ DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
VOLATILE
AS $$
DECLARE

    v_idempotency_key TEXT;

    v_existing_id UUID;

    v_external_existing_id UUID;

    v_message core.messages%ROWTYPE;

    v_idle_timeout INTEGER := 1440;

BEGIN

    -- ========================================================
    -- IDEMPOTENCY KEY
    -- ========================================================

    v_idempotency_key :=
        NULLIF(
            TRIM(p_idempotency_key),
            ''
        );


    /*
     * Em produção, se o chamador não fornecer uma chave,
     * podemos usar o ID oficial da mensagem do provedor.
     */
    IF v_idempotency_key IS NULL
       AND NULLIF(TRIM(p_external_message_id), '') IS NOT NULL
    THEN

        v_idempotency_key :=
            'IN:'
            || UPPER(COALESCE(p_provider, 'UNKNOWN'))
            || ':'
            || p_external_message_id;

    END IF;


    IF v_idempotency_key IS NULL
    THEN

        RETURN JSONB_BUILD_OBJECT(
            'ok', FALSE,
            'code', 'IDEMPOTENCY_KEY_REQUIRED'
        );

    END IF;


    -- ========================================================
    -- VALIDAR CONTEXTO MULTI-TENANT
    -- ========================================================

    IF NOT EXISTS (

        SELECT 1

        FROM core.conversations c

        JOIN core.customer_channels cc
          ON cc.business_id =
                c.business_id

         AND cc.customer_id =
                c.customer_id

        WHERE c.business_id =
                p_business_id

          AND c.id =
                p_conversation_id

          AND c.customer_id =
                p_customer_id

          AND cc.id =
                p_customer_channel_id

          AND cc.channel_type =
                p_channel_type

          AND cc.provider =
                p_provider
    )
    THEN

        RETURN JSONB_BUILD_OBJECT(
            'ok', FALSE,
            'code', 'INVALID_MESSAGE_CONTEXT'
        );

    END IF;


    -- ========================================================
    -- LOCK POR IDENTIDADE DA MENSAGEM
    -- ========================================================

    PERFORM pg_advisory_xact_lock(
        hashtextextended(
            p_business_id::TEXT
            || '|'
            || v_idempotency_key,
            0
        )
    );


    IF NULLIF(TRIM(p_external_message_id), '') IS NOT NULL
    THEN

        PERFORM pg_advisory_xact_lock(
            hashtextextended(
                p_business_id::TEXT
                || '|'
                || COALESCE(p_provider, '')
                || '|'
                || p_external_message_id,
                0
            )
        );

    END IF;


    -- ========================================================
    -- PROCURAR PELA IDEMPOTÊNCIA
    -- ========================================================

    SELECT m.id

    INTO v_existing_id

    FROM core.messages m

    WHERE m.business_id =
            p_business_id

      AND m.idempotency_key =
            v_idempotency_key

    LIMIT 1;


    -- ========================================================
    -- PROCURAR PELO ID EXTERNO
    -- ========================================================

    IF NULLIF(TRIM(p_external_message_id), '') IS NOT NULL
    THEN

        SELECT m.id

        INTO v_external_existing_id

        FROM core.messages m

        WHERE m.business_id =
                p_business_id

          AND m.provider =
                p_provider

          AND m.external_message_id =
                p_external_message_id

        LIMIT 1;

    END IF;


    -- ========================================================
    -- IDENTIDADES APONTANDO PARA MENSAGENS DIFERENTES
    -- ========================================================

    IF v_existing_id IS NOT NULL
       AND v_external_existing_id IS NOT NULL
       AND v_existing_id <> v_external_existing_id
    THEN

        RETURN JSONB_BUILD_OBJECT(
            'ok', FALSE,
            'code', 'MESSAGE_IDENTITY_CONFLICT',
            'idempotency_message_id', v_existing_id,
            'external_message_id_owner',
                v_external_existing_id
        );

    END IF;


    -- ========================================================
    -- DUPLICATA
    -- ========================================================

    v_existing_id :=
        COALESCE(
            v_existing_id,
            v_external_existing_id
        );


    IF v_existing_id IS NOT NULL
    THEN

        SELECT *

        INTO v_message

        FROM core.messages

        WHERE id =
                v_existing_id;


        RETURN JSONB_BUILD_OBJECT(

            'ok',
                TRUE,

            'code',
                'INBOUND_DUPLICATE',

            'duplicate',
                TRUE,

            'should_process',
                FALSE,

            'message_id',
                v_message.id,

            'processing_status',
                v_message.processing_status,

            'external_message_id',
                v_message.external_message_id
        );

    END IF;


    -- ========================================================
    -- INSERIR
    -- ========================================================

    BEGIN

        INSERT INTO core.messages (

            business_id,

            conversation_id,

            customer_id,

            customer_channel_id,

            direction,

            channel_type,

            provider,

            idempotency_key,

            external_message_id,

            message_type,

            text_content,

            raw_payload,

            canonical_payload,

            processing_status,

            delivery_status,

            provider_timestamp
        )

        VALUES (

            p_business_id,

            p_conversation_id,

            p_customer_id,

            p_customer_channel_id,

            'INBOUND',

            p_channel_type,

            p_provider,

            v_idempotency_key,

            NULLIF(
                TRIM(p_external_message_id),
                ''
            ),

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

            COALESCE(
                p_canonical_payload,
                '{}'::JSONB
            ),

            'RECEIVED',

            'NOT_APPLICABLE',

            p_provider_timestamp
        )

        RETURNING *

        INTO v_message;


    EXCEPTION

        WHEN unique_violation
        THEN

            /*
             * Proteção adicional caso outra transação tenha
             * vencido a corrida apesar das verificações.
             */

            SELECT *

            INTO v_message

            FROM core.messages m

            WHERE m.business_id =
                    p_business_id

              AND (
                    m.idempotency_key =
                        v_idempotency_key

                    OR (

                        p_external_message_id IS NOT NULL

                        AND m.provider =
                            p_provider

                        AND m.external_message_id =
                            p_external_message_id
                    )
                  )

            ORDER BY m.created_at

            LIMIT 1;


            IF FOUND
            THEN

                RETURN JSONB_BUILD_OBJECT(

                    'ok',
                        TRUE,

                    'code',
                        'INBOUND_DUPLICATE',

                    'duplicate',
                        TRUE,

                    'should_process',
                        FALSE,

                    'message_id',
                        v_message.id
                );

            END IF;


            RAISE;

    END;


    -- ========================================================
    -- ATUALIZAR ATIVIDADE DA CONVERSA
    -- ========================================================

    SELECT
        COALESCE(
            bs.conversation_idle_timeout_minutes,
            1440
        )

    INTO v_idle_timeout

    FROM core.business_settings bs

    WHERE bs.business_id =
            p_business_id

    LIMIT 1;


    v_idle_timeout :=
        COALESCE(
            v_idle_timeout,
            1440
        );


    UPDATE core.conversations

    SET
        last_message_at =
            NOW(),

        last_inbound_at =
            NOW(),

        session_expires_at =
            NOW()
            + MAKE_INTERVAL(
                mins => v_idle_timeout
            )

    WHERE business_id =
            p_business_id

      AND id =
            p_conversation_id;


    -- ========================================================
    -- RESULTADO
    -- ========================================================

    RETURN JSONB_BUILD_OBJECT(

        'ok',
            TRUE,

        'code',
            'INBOUND_REGISTERED',

        'duplicate',
            FALSE,

        'should_process',
            TRUE,

        'message_id',
            v_message.id,

        'processing_status',
            v_message.processing_status,

        'external_message_id',
            v_message.external_message_id
    );

END;
$$;



-- ============================================================
-- 3. ATUALIZAR PROCESSAMENTO DO INBOUND
-- ============================================================

CREATE OR REPLACE FUNCTION core.update_inbound_message_processing(

    p_business_id UUID,

    p_message_id UUID,

    p_status TEXT,

    p_intent_detected TEXT DEFAULT NULL,

    p_intent_confidence NUMERIC DEFAULT NULL,

    p_processing_error TEXT DEFAULT NULL,

    p_canonical_patch JSONB DEFAULT '{}'::JSONB
)
RETURNS JSONB
LANGUAGE plpgsql
VOLATILE
AS $$
DECLARE

    v_message core.messages%ROWTYPE;

    v_status TEXT;

BEGIN

    v_status :=
        UPPER(
            COALESCE(
                NULLIF(TRIM(p_status), ''),
                ''
            )
        );


    IF v_status NOT IN (
        'PROCESSING',
        'PROCESSED',
        'FAILED',
        'IGNORED'
    )
    THEN

        RETURN JSONB_BUILD_OBJECT(
            'ok', FALSE,
            'code', 'INVALID_PROCESSING_STATUS'
        );

    END IF;


    IF p_intent_confidence IS NOT NULL
       AND (
            p_intent_confidence < 0
            OR p_intent_confidence > 1
       )
    THEN

        RETURN JSONB_BUILD_OBJECT(
            'ok', FALSE,
            'code', 'INVALID_INTENT_CONFIDENCE'
        );

    END IF;


    SELECT *

    INTO v_message

    FROM core.messages

    WHERE business_id =
            p_business_id

      AND id =
            p_message_id

      AND direction =
            'INBOUND'

    FOR UPDATE;


    IF NOT FOUND
    THEN

        RETURN JSONB_BUILD_OBJECT(
            'ok', FALSE,
            'code', 'INBOUND_MESSAGE_NOT_FOUND'
        );

    END IF;


    UPDATE core.messages

    SET

        processing_status =
            v_status,

        processing_error =
            p_processing_error,

        intent_detected =
            COALESCE(
                p_intent_detected,
                intent_detected
            ),

        intent_confidence =
            COALESCE(
                p_intent_confidence,
                intent_confidence
            ),

        canonical_payload =
            canonical_payload
            ||
            COALESCE(
                p_canonical_patch,
                '{}'::JSONB
            ),

        processed_at =
            CASE

                WHEN v_status IN (
                    'PROCESSED',
                    'FAILED',
                    'IGNORED'
                )
                THEN NOW()

                ELSE processed_at

            END

    WHERE business_id =
            p_business_id

      AND id =
            p_message_id;


    RETURN JSONB_BUILD_OBJECT(

        'ok',
            TRUE,

        'code',
            'INBOUND_PROCESSING_UPDATED',

        'message_id',
            p_message_id,

        'processing_status',
            v_status
    );

END;
$$;



-- ============================================================
-- 4. REGISTRAR MENSAGEM OUTBOUND
--
-- OUTBOX:
--
-- primeiro registramos no banco como QUEUED;
-- depois o n8n envia.
--
-- Se houver retry com a mesma idempotency_key,
-- NÃO criamos nem autorizamos um segundo envio.
-- ============================================================

CREATE OR REPLACE FUNCTION core.register_outbound_message(

    p_business_id UUID,

    p_conversation_id UUID,

    p_customer_id UUID,

    p_customer_channel_id UUID,

    p_channel_type TEXT,

    p_provider TEXT,

    p_idempotency_key TEXT,

    p_text_content TEXT,

    p_message_type TEXT DEFAULT 'TEXT',

    p_reply_to_external_message_id TEXT DEFAULT NULL,

    p_canonical_payload JSONB DEFAULT '{}'::JSONB
)
RETURNS JSONB
LANGUAGE plpgsql
VOLATILE
AS $$
DECLARE

    v_key TEXT;

    v_message core.messages%ROWTYPE;

BEGIN

    v_key :=
        NULLIF(
            TRIM(p_idempotency_key),
            ''
        );


    IF v_key IS NULL
    THEN

        RETURN JSONB_BUILD_OBJECT(
            'ok', FALSE,
            'code', 'IDEMPOTENCY_KEY_REQUIRED'
        );

    END IF;


    IF NULLIF(TRIM(p_text_content), '') IS NULL
    THEN

        RETURN JSONB_BUILD_OBJECT(
            'ok', FALSE,
            'code', 'OUTBOUND_TEXT_REQUIRED'
        );

    END IF;


    -- ========================================================
    -- CONTEXTO
    -- ========================================================

    IF NOT EXISTS (

        SELECT 1

        FROM core.conversations c

        JOIN core.customer_channels cc
          ON cc.business_id =
                c.business_id

         AND cc.customer_id =
                c.customer_id

        WHERE c.business_id =
                p_business_id

          AND c.id =
                p_conversation_id

          AND c.customer_id =
                p_customer_id

          AND cc.id =
                p_customer_channel_id

          AND cc.channel_type =
                p_channel_type

          AND cc.provider =
                p_provider
    )
    THEN

        RETURN JSONB_BUILD_OBJECT(
            'ok', FALSE,
            'code', 'INVALID_MESSAGE_CONTEXT'
        );

    END IF;


    PERFORM pg_advisory_xact_lock(
        hashtextextended(
            p_business_id::TEXT
            || '|'
            || v_key,
            0
        )
    );


    -- ========================================================
    -- JÁ EXISTE?
    -- ========================================================

    SELECT *

    INTO v_message

    FROM core.messages m

    WHERE m.business_id =
            p_business_id

      AND m.idempotency_key =
            v_key

    LIMIT 1;


    IF FOUND
    THEN

        RETURN JSONB_BUILD_OBJECT(

            'ok',
                TRUE,

            'code',
                'OUTBOUND_DUPLICATE',

            'duplicate',
                TRUE,

            /*
             * Evitamos envio duplicado.
             *
             * Caso tenha ficado QUEUED por falha do workflow,
             * futuramente o retry worker cuida disso.
             */
            'should_send',
                FALSE,

            'message_id',
                v_message.id,

            'delivery_status',
                v_message.delivery_status,

            'external_message_id',
                v_message.external_message_id
        );

    END IF;


    -- ========================================================
    -- INSERIR NO OUTBOX
    -- ========================================================

    INSERT INTO core.messages (

        business_id,

        conversation_id,

        customer_id,

        customer_channel_id,

        direction,

        channel_type,

        provider,

        idempotency_key,

        reply_to_external_message_id,

        message_type,

        text_content,

        canonical_payload,

        processing_status,

        processed_at,

        delivery_status
    )

    VALUES (

        p_business_id,

        p_conversation_id,

        p_customer_id,

        p_customer_channel_id,

        'OUTBOUND',

        p_channel_type,

        p_provider,

        v_key,

        p_reply_to_external_message_id,

        UPPER(
            COALESCE(
                NULLIF(TRIM(p_message_type), ''),
                'TEXT'
            )
        ),

        p_text_content,

        COALESCE(
            p_canonical_payload,
            '{}'::JSONB
        ),

        'PROCESSED',

        NOW(),

        'QUEUED'
    )

    RETURNING *

    INTO v_message;


    UPDATE core.conversations

    SET
        last_message_at =
            NOW(),

        last_outbound_at =
            NOW()

    WHERE business_id =
            p_business_id

      AND id =
            p_conversation_id;


    RETURN JSONB_BUILD_OBJECT(

        'ok',
            TRUE,

        'code',
            'OUTBOUND_REGISTERED',

        'duplicate',
            FALSE,

        'should_send',
            TRUE,

        'message_id',
            v_message.id,

        'delivery_status',
            v_message.delivery_status
    );

END;
$$;



-- ============================================================
-- 5. APLICAR STATUS DE ENTREGA
--
-- Pode ser chamado:
-- - depois do bind;
-- - antes do bind.
--
-- Se mensagem ainda não estiver vinculada ao external ID,
-- o evento fica pendente.
-- ============================================================

CREATE OR REPLACE FUNCTION core.apply_message_delivery_status(

    p_business_id UUID,

    p_provider TEXT,

    p_external_message_id TEXT,

    p_delivery_status TEXT,

    p_provider_timestamp TIMESTAMPTZ DEFAULT NULL,

    p_error_detail TEXT DEFAULT NULL,

    p_raw_payload JSONB DEFAULT '{}'::JSONB
)
RETURNS JSONB
LANGUAGE plpgsql
VOLATILE
AS $$
DECLARE

    v_status TEXT;

    v_event_key TEXT;

    v_event_id UUID;

    v_message core.messages%ROWTYPE;

    v_previous_status TEXT;

    v_apply BOOLEAN := FALSE;

BEGIN

    v_status :=
        UPPER(
            COALESCE(
                NULLIF(
                    TRIM(p_delivery_status),
                    ''
                ),
                ''
            )
        );


    IF v_status NOT IN (
        'SENT',
        'DELIVERED',
        'READ',
        'FAILED'
    )
    THEN

        RETURN JSONB_BUILD_OBJECT(
            'ok', FALSE,
            'code', 'INVALID_DELIVERY_STATUS'
        );

    END IF;


    IF NULLIF(
        TRIM(p_external_message_id),
        ''
    ) IS NULL
    THEN

        RETURN JSONB_BUILD_OBJECT(
            'ok', FALSE,
            'code', 'EXTERNAL_MESSAGE_ID_REQUIRED'
        );

    END IF;


    -- ========================================================
    -- CHAVE IDEMPOTENTE DO CALLBACK
    -- ========================================================

    v_event_key :=
        MD5(
            p_business_id::TEXT
            || '|'
            || COALESCE(p_provider, '')
            || '|'
            || p_external_message_id
            || '|'
            || v_status
            || '|'
            || COALESCE(
                p_provider_timestamp::TEXT,
                ''
            )
        );


    INSERT INTO core.message_delivery_events (

        business_id,

        provider,

        external_message_id,

        delivery_status,

        provider_timestamp,

        error_detail,

        raw_payload,

        event_key
    )

    VALUES (

        p_business_id,

        p_provider,

        p_external_message_id,

        v_status,

        p_provider_timestamp,

        p_error_detail,

        COALESCE(
            p_raw_payload,
            '{}'::JSONB
        ),

        v_event_key
    )

    ON CONFLICT (event_key)
    DO NOTHING

    RETURNING id

    INTO v_event_id;


    IF v_event_id IS NULL
    THEN

        SELECT id

        INTO v_event_id

        FROM core.message_delivery_events

        WHERE event_key =
                v_event_key

        LIMIT 1;

    END IF;


    -- ========================================================
    -- PROCURAR MENSAGEM
    -- ========================================================

    SELECT *

    INTO v_message

    FROM core.messages m

    WHERE m.business_id =
            p_business_id

      AND m.provider =
            p_provider

      AND m.external_message_id =
            p_external_message_id

      AND m.direction =
            'OUTBOUND'

    FOR UPDATE;


    -- ========================================================
    -- CALLBACK CHEGOU ANTES DO BIND
    -- ========================================================

    IF NOT FOUND
    THEN

        RETURN JSONB_BUILD_OBJECT(

            'ok',
                TRUE,

            'code',
                'DELIVERY_EVENT_PENDING_BIND',

            'pending_bind',
                TRUE,

            'event_id',
                v_event_id,

            'delivery_status',
                v_status
        );

    END IF;


    v_previous_status :=
        v_message.delivery_status;


    -- ========================================================
    -- TRANSIÇÕES MONOTÔNICAS
    --
    -- Permite pular etapas:
    --
    -- QUEUED → DELIVERED
    -- QUEUED → READ
    --
    -- caso os callbacks cheguem fora de ordem.
    -- ========================================================

    v_apply :=
        CASE v_previous_status

            WHEN 'QUEUED'
            THEN
                v_status IN (
                    'SENT',
                    'DELIVERED',
                    'READ',
                    'FAILED'
                )

            WHEN 'SENT'
            THEN
                v_status IN (
                    'DELIVERED',
                    'READ',
                    'FAILED'
                )

            WHEN 'DELIVERED'
            THEN
                v_status = 'READ'

            WHEN 'READ'
            THEN
                FALSE

            WHEN 'FAILED'
            THEN
                FALSE

            ELSE
                FALSE

        END;


    IF v_apply
    THEN

        UPDATE core.messages

        SET

            delivery_status =
                v_status,

            provider_timestamp =
                COALESCE(
                    p_provider_timestamp,
                    provider_timestamp
                ),

            sent_at =
                CASE

                    WHEN v_status IN (
                        'SENT',
                        'DELIVERED',
                        'READ'
                    )
                    THEN
                        COALESCE(
                            sent_at,
                            p_provider_timestamp,
                            NOW()
                        )

                    ELSE
                        sent_at

                END

        WHERE id =
                v_message.id;

    END IF;


    -- Mesmo se o status for antigo/duplicado,
    -- o evento já pôde ser associado à mensagem.

    UPDATE core.message_delivery_events

    SET
        applied_message_id =
            v_message.id,

        applied_at =
            NOW()

    WHERE id =
            v_event_id;


    RETURN JSONB_BUILD_OBJECT(

        'ok',
            TRUE,

        'code',
            CASE
                WHEN v_apply
                THEN 'DELIVERY_STATUS_APPLIED'
                ELSE 'DELIVERY_STATUS_IGNORED'
            END,

        'message_id',
            v_message.id,

        'event_id',
            v_event_id,

        'applied',
            v_apply,

        'previous_status',
            v_previous_status,

        'delivery_status',
            CASE
                WHEN v_apply
                THEN v_status
                ELSE v_previous_status
            END
    );

END;
$$;



-- ============================================================
-- 6. VINCULAR ID DA META / PROVEDOR AO OUTBOUND
-- ============================================================

CREATE OR REPLACE FUNCTION core.bind_outbound_external_message(

    p_business_id UUID,

    p_message_id UUID,

    p_provider TEXT,

    p_external_message_id TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
VOLATILE
AS $$
DECLARE

    v_message core.messages%ROWTYPE;

    v_conflicting_message UUID;

    v_event RECORD;

BEGIN

    IF NULLIF(
        TRIM(p_external_message_id),
        ''
    ) IS NULL
    THEN

        RETURN JSONB_BUILD_OBJECT(
            'ok', FALSE,
            'code', 'EXTERNAL_MESSAGE_ID_REQUIRED'
        );

    END IF;


    PERFORM pg_advisory_xact_lock(
        hashtextextended(
            p_business_id::TEXT
            || '|'
            || p_provider
            || '|'
            || p_external_message_id,
            0
        )
    );


    SELECT *

    INTO v_message

    FROM core.messages

    WHERE business_id =
            p_business_id

      AND id =
            p_message_id

      AND direction =
            'OUTBOUND'

    FOR UPDATE;


    IF NOT FOUND
    THEN

        RETURN JSONB_BUILD_OBJECT(
            'ok', FALSE,
            'code', 'OUTBOUND_MESSAGE_NOT_FOUND'
        );

    END IF;


    IF v_message.provider <> p_provider
    THEN

        RETURN JSONB_BUILD_OBJECT(
            'ok', FALSE,
            'code', 'PROVIDER_MISMATCH'
        );

    END IF;


    IF v_message.external_message_id IS NOT NULL
       AND v_message.external_message_id <> p_external_message_id
    THEN

        RETURN JSONB_BUILD_OBJECT(

            'ok',
                FALSE,

            'code',
                'MESSAGE_ALREADY_BOUND',

            'current_external_message_id',
                v_message.external_message_id
        );

    END IF;


    SELECT m.id

    INTO v_conflicting_message

    FROM core.messages m

    WHERE m.business_id =
            p_business_id

      AND m.provider =
            p_provider

      AND m.external_message_id =
            p_external_message_id

      AND m.id <>
            p_message_id

    LIMIT 1;


    IF v_conflicting_message IS NOT NULL
    THEN

        RETURN JSONB_BUILD_OBJECT(

            'ok',
                FALSE,

            'code',
                'EXTERNAL_MESSAGE_ID_ALREADY_BOUND',

            'existing_message_id',
                v_conflicting_message
        );

    END IF;


    UPDATE core.messages

    SET external_message_id =
            p_external_message_id

    WHERE business_id =
            p_business_id

      AND id =
            p_message_id;


    -- ========================================================
    -- REAPLICAR CALLBACKS QUE CHEGARAM ANTES DO BIND
    -- ========================================================

    FOR v_event IN

        SELECT
            e.delivery_status,
            e.provider_timestamp,
            e.error_detail,
            e.raw_payload

        FROM core.message_delivery_events e

        WHERE e.business_id =
                p_business_id

          AND e.provider =
                p_provider

          AND e.external_message_id =
                p_external_message_id

          AND e.applied_at IS NULL

        ORDER BY
            e.provider_timestamp ASC NULLS LAST,
            e.created_at ASC

    LOOP

        PERFORM core.apply_message_delivery_status(

            p_business_id,

            p_provider,

            p_external_message_id,

            v_event.delivery_status,

            v_event.provider_timestamp,

            v_event.error_detail,

            v_event.raw_payload
        );

    END LOOP;


    SELECT *

    INTO v_message

    FROM core.messages

    WHERE business_id =
            p_business_id

      AND id =
            p_message_id;


    RETURN JSONB_BUILD_OBJECT(

        'ok',
            TRUE,

        'code',
            'OUTBOUND_EXTERNAL_ID_BOUND',

        'message_id',
            v_message.id,

        'external_message_id',
            v_message.external_message_id,

        'delivery_status',
            v_message.delivery_status
    );

END;
$$;



-- ============================================================
-- 7. HISTÓRICO RECENTE PARA A IA
--
-- Não envia raw_payload.
-- Não envia estrutura técnica desnecessária.
-- Só informação conversacional útil.
-- ============================================================

CREATE OR REPLACE FUNCTION core.get_recent_conversation_messages(

    p_business_id UUID,

    p_conversation_id UUID,

    p_limit INTEGER DEFAULT 12
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
AS $$
DECLARE

    v_limit INTEGER;

    v_result JSONB;

BEGIN

    v_limit :=
        LEAST(
            GREATEST(
                COALESCE(
                    p_limit,
                    12
                ),
                1
            ),
            50
        );


    SELECT COALESCE(

        JSONB_AGG(

            JSONB_BUILD_OBJECT(

                'message_id',
                    x.id,

                'direction',
                    x.direction,

                'message_type',
                    x.message_type,

                'text',
                    x.text_content,

                'intent',
                    x.intent_detected,

                'intent_confidence',
                    x.intent_confidence,

                'at',
                    COALESCE(
                        x.provider_timestamp,
                        x.created_at
                    )
            )

            ORDER BY x.created_at ASC
        ),

        '[]'::JSONB
    )

    INTO v_result

    FROM (

        SELECT m.*

        FROM core.messages m

        WHERE m.business_id =
                p_business_id

          AND m.conversation_id =
                p_conversation_id

          AND m.direction IN (
                'INBOUND',
                'OUTBOUND'
          )

        ORDER BY m.created_at DESC

        LIMIT v_limit

    ) x;


    RETURN v_result;

END;
$$;