-- ============================================================
-- 037_cancellation_outbound_messaging
-- ============================================================

CREATE OR REPLACE FUNCTION
core.prepare_appointment_cancellation_outbound(
    p_business_id UUID,
    p_appointment_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql
VOLATILE
AS $$
DECLARE

    v_notice JSONB;
    v_context JSONB;
    v_register_result JSONB;

    v_business_code TEXT;
    v_recipient TEXT;

    v_conversation_id UUID;
    v_customer_id UUID;
    v_customer_channel_id UUID;
    v_business_channel_id UUID;

    v_last_inbound_at TIMESTAMPTZ;
    v_window_expires_at TIMESTAMPTZ;
    v_window_open BOOLEAN := FALSE;

    v_customer_name TEXT;
    v_professional_name TEXT;
    v_service_summary TEXT;
    v_local_date TEXT;
    v_local_start TEXT;
    v_public_reason TEXT;
    v_actor_type TEXT;

    v_rebooking_enabled BOOLEAN := FALSE;
    v_button_id TEXT;
    v_button_text TEXT;

    v_text TEXT;

    v_idempotency_key TEXT;

    v_message_type TEXT;
    v_canonical_payload JSONB;
    v_meta_payload JSONB;

    v_internal_message_id UUID;
    v_should_send BOOLEAN := FALSE;

BEGIN

    -- ========================================================
    -- 1. PREPARAR NOTIFICAÇÃO DE CANCELAMENTO
    -- ========================================================

    v_notice :=
        core.prepare_appointment_cancellation_notification(
            p_business_id,
            p_appointment_id
        );


    IF COALESCE(
        (v_notice ->> 'ok')::BOOLEAN,
        FALSE
    ) IS NOT TRUE
    THEN

        RETURN JSONB_BUILD_OBJECT(
            'ok', FALSE,
            'code',
                COALESCE(
                    v_notice ->> 'code',
                    'CANCELLATION_NOTIFICATION_PREPARATION_FAILED'
                ),
            'notification',
                v_notice
        );

    END IF;


    -- Já enviada / não necessária.
    IF COALESCE(
        (v_notice ->> 'should_send')::BOOLEAN,
        FALSE
    ) IS NOT TRUE
    THEN

        RETURN JSONB_BUILD_OBJECT(
            'ok', TRUE,
            'code',
                COALESCE(
                    v_notice ->> 'code',
                    'CANCELLATION_NOTIFICATION_SKIPPED'
                ),
            'should_send', FALSE,
            'notification', v_notice
        );

    END IF;


    -- ========================================================
    -- 2. EXTRAIR IDENTIDADE
    -- ========================================================

    v_business_code :=
        v_notice #>> '{business,business_code}';


    v_recipient :=
        v_notice #>> '{customer,recipient}';


    IF v_business_code IS NULL
       OR v_recipient IS NULL
    THEN

        RETURN JSONB_BUILD_OBJECT(
            'ok', FALSE,
            'code', 'CANCELLATION_OUTBOUND_IDENTITY_MISSING'
        );

    END IF;


    -- ========================================================
    -- 3. RESOLVER/CRIAR CONTEXTO DA CONVERSA
    -- ========================================================

    v_context :=
        core.prepare_assistant_context(
            v_business_code,
            'WHATSAPP',
            'META',
            v_recipient
        );


    IF COALESCE(
        (v_context ->> 'ok')::BOOLEAN,
        FALSE
    ) IS NOT TRUE
    THEN

        RETURN JSONB_BUILD_OBJECT(
            'ok', FALSE,
            'code', 'ASSISTANT_CONTEXT_PREPARATION_FAILED',
            'context', v_context
        );

    END IF;


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


    v_business_channel_id :=
        NULLIF(
            v_context #>> '{channel,id}',
            ''
        )::UUID;


    IF v_conversation_id IS NULL
       OR v_customer_id IS NULL
       OR v_customer_channel_id IS NULL
       OR v_business_channel_id IS NULL
    THEN

        RETURN JSONB_BUILD_OBJECT(
            'ok', FALSE,
            'code', 'CONVERSATION_CONTEXT_INCOMPLETE'
        );

    END IF;


    -- ========================================================
    -- 4. JANELA DE ATENDIMENTO DO WHATSAPP
    --
    -- Fonte: última mensagem INBOUND real do cliente.
    -- Não usamos simplesmente "conversa aberta".
    -- ========================================================

    SELECT
        c.last_inbound_at

    INTO
        v_last_inbound_at

    FROM core.conversations c

    WHERE c.business_id = p_business_id
      AND c.id = v_conversation_id

    LIMIT 1;


    IF v_last_inbound_at IS NOT NULL
    THEN

        v_window_expires_at :=
            v_last_inbound_at
            + INTERVAL '24 hours';


        v_window_open :=
            NOW() <= v_window_expires_at;

    END IF;


    -- ========================================================
    -- 5. DADOS HUMANOS
    -- ========================================================

    v_customer_name :=
        COALESCE(
            NULLIF(
                BTRIM(
                    v_notice #>> '{customer,name}'
                ),
                ''
            ),
            'Olá'
        );


    v_professional_name :=
        COALESCE(
            NULLIF(
                BTRIM(
                    v_notice #>> '{professional,name}'
                ),
                ''
            ),
            'profissional'
        );


    v_service_summary :=
        COALESCE(
            NULLIF(
                BTRIM(
                    v_notice #>> '{appointment,service_summary}'
                ),
                ''
            ),
            'atendimento'
        );


    v_local_date :=
        v_notice #>> '{appointment,local_date}';


    v_local_start :=
        v_notice #>> '{appointment,local_start}';


    v_public_reason :=
        NULLIF(
            BTRIM(
                v_notice #>> '{cancellation,public_reason}'
            ),
            ''
        );


    v_actor_type :=
        v_notice #>> '{cancellation,actor_type}';


    v_rebooking_enabled :=
        COALESCE(
            (
                v_notice
                #>>
                '{rebooking,enabled}'
            )::BOOLEAN,
            FALSE
        );


    v_button_id :=
        v_notice
        #>>
        '{rebooking,button_id}';


    v_button_text :=
        v_notice
        #>>
        '{rebooking,button_text}';


    v_idempotency_key :=
        v_notice ->> 'idempotency_key';


    -- ========================================================
    -- 6. TEXTO DA NOTIFICAÇÃO
    -- ========================================================

    IF v_actor_type = 'CUSTOMER'
    THEN

        v_text :=
            FORMAT(
                '%s, seu horário de %s com %s no dia %s às %s foi cancelado com sucesso.',
                v_customer_name,
                v_service_summary,
                v_professional_name,
                v_local_date,
                v_local_start
            );

    ELSE

        v_text :=
            FORMAT(
                '%s, seu horário de %s com %s no dia %s às %s precisou ser cancelado.',
                v_customer_name,
                v_service_summary,
                v_professional_name,
                v_local_date,
                v_local_start
            );


        IF v_public_reason IS NOT NULL
        THEN

            v_text :=
                v_text
                || E'\n\n'
                || 'Motivo informado: "'
                || v_public_reason
                || '".';

        END IF;


        IF v_rebooking_enabled
        THEN

            v_text :=
                v_text
                || E'\n\n'
                || 'Se quiser, posso procurar outro horário para você.';

        END IF;

    END IF;


    -- ========================================================
    -- 7. FORA DA JANELA DE 24H
    --
    -- Não enviamos mensagem livre.
    -- Um template de utilidade aprovado será conectado depois.
    -- ========================================================

    IF v_window_open IS NOT TRUE
    THEN

        RETURN JSONB_BUILD_OBJECT(

            'ok',
                TRUE,

            'code',
                'WHATSAPP_TEMPLATE_REQUIRED',

            'should_send',
                FALSE,

            'delivery_mode',
                'TEMPLATE_REQUIRED',

            'appointment_id',
                p_appointment_id,

            'conversation_id',
                v_conversation_id,

            'customer_id',
                v_customer_id,

            'customer_channel_id',
                v_customer_channel_id,

            'business_channel_id',
                v_business_channel_id,

            'recipient',
                v_recipient,

            'phone_number_id',
                v_notice #>> '{channel,phone_number_id}',

            'last_inbound_at',
                v_last_inbound_at,

            'window_expires_at',
                v_window_expires_at,

            'template_context',
                JSONB_BUILD_OBJECT(

                    'notification_type',
                        'APPOINTMENT_CANCELLED',

                    'customer_name',
                        v_customer_name,

                    'service_name',
                        v_service_summary,

                    'professional_name',
                        v_professional_name,

                    'local_date',
                        v_local_date,

                    'local_start',
                        v_local_start,

                    'public_reason',
                        v_public_reason,

                    'offer_rebooking',
                        v_rebooking_enabled,

                    'appointment_id',
                        p_appointment_id
                )
        );

    END IF;


    -- ========================================================
    -- 8. PAYLOAD CANÔNICO INTERNO
    -- ========================================================

    v_canonical_payload :=
        JSONB_BUILD_OBJECT(

            'notification_type',
                'APPOINTMENT_CANCELLED',

            'appointment_id',
                p_appointment_id,

            'cancellation_id',
                v_notice
                #>>
                '{cancellation,cancellation_id}',

            'actor_type',
                v_actor_type,

            'public_reason',
                v_public_reason,

            'rebooking',
                JSONB_BUILD_OBJECT(
                    'enabled',
                        v_rebooking_enabled,
                    'button_id',
                        v_button_id
                )
        );


    -- ========================================================
    -- 9. TIPO DA MENSAGEM
    -- ========================================================

    IF v_rebooking_enabled
       AND v_button_id IS NOT NULL
    THEN

        v_message_type :=
            'INTERACTIVE';

    ELSE

        v_message_type :=
            'TEXT';

    END IF;


    -- ========================================================
    -- 10. REGISTRAR OUTBOUND NO CORE
    -- ========================================================

    v_register_result :=
        core.register_outbound_message(

            p_business_id,

            v_conversation_id,

            v_customer_id,

            v_customer_channel_id,

            'WHATSAPP',

            'META',

            v_idempotency_key,

            v_text,

            v_message_type,

            NULL,

            v_canonical_payload
        );


    IF COALESCE(
        (v_register_result ->> 'ok')::BOOLEAN,
        FALSE
    ) IS NOT TRUE
    THEN

        RETURN JSONB_BUILD_OBJECT(

            'ok',
                FALSE,

            'code',
                'CANCELLATION_OUTBOUND_REGISTRATION_FAILED',

            'registration',
                v_register_result
        );

    END IF;


    v_internal_message_id :=
        NULLIF(
            v_register_result ->> 'message_id',
            ''
        )::UUID;


    v_should_send :=
        COALESCE(
            (
                v_register_result
                ->>
                'should_send'
            )::BOOLEAN,
            FALSE
        );


    -- ========================================================
    -- 11. PAYLOAD META
    -- ========================================================

    IF v_message_type = 'INTERACTIVE'
    THEN

        v_meta_payload :=
            JSONB_BUILD_OBJECT(

                'messaging_product',
                    'whatsapp',

                'recipient_type',
                    'individual',

                'to',
                    v_recipient,

                'type',
                    'interactive',

                'interactive',
                    JSONB_BUILD_OBJECT(

                        'type',
                            'button',

                        'body',
                            JSONB_BUILD_OBJECT(
                                'text',
                                    v_text
                            ),

                        'action',
                            JSONB_BUILD_OBJECT(

                                'buttons',
                                    JSONB_BUILD_ARRAY(

                                        JSONB_BUILD_OBJECT(

                                            'type',
                                                'reply',

                                            'reply',
                                                JSONB_BUILD_OBJECT(

                                                    'id',
                                                        v_button_id,

                                                    'title',
                                                        COALESCE(
                                                            v_button_text,
                                                            'Ver outros horários'
                                                        )
                                                )
                                        )
                                    )
                            )
                    )
            );

    ELSE

        v_meta_payload :=
            JSONB_BUILD_OBJECT(

                'messaging_product',
                    'whatsapp',

                'recipient_type',
                    'individual',

                'to',
                    v_recipient,

                'type',
                    'text',

                'text',
                    JSONB_BUILD_OBJECT(
                        'body',
                            v_text
                    )
            );

    END IF;


    -- ========================================================
    -- 12. RETORNO
    -- ========================================================

    RETURN JSONB_BUILD_OBJECT(

        'ok',
            TRUE,

        'code',
            CASE
                WHEN v_should_send
                    THEN 'CANCELLATION_OUTBOUND_READY'
                ELSE 'CANCELLATION_OUTBOUND_ALREADY_REGISTERED'
            END,

        'should_send',
            v_should_send,

        'delivery_mode',
            'SESSION',

        'message_type',
            v_message_type,

        'internal_message_id',
            v_internal_message_id,

        'conversation_id',
            v_conversation_id,

        'business_channel_id',
            v_business_channel_id,

        'customer_id',
            v_customer_id,

        'customer_channel_id',
            v_customer_channel_id,

        'recipient',
            v_recipient,

        'phone_number_id',
            v_notice #>> '{channel,phone_number_id}',

        'text',
            v_text,

        'last_inbound_at',
            v_last_inbound_at,

        'window_expires_at',
            v_window_expires_at,

        'meta_payload',
            v_meta_payload,

        'registration',
            v_register_result
    );

END;
$$;