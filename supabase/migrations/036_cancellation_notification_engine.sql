-- ============================================================
-- 036_cancellation_notification_engine
-- ============================================================

CREATE OR REPLACE FUNCTION
core.prepare_appointment_cancellation_notification(
    p_business_id UUID,
    p_appointment_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql
VOLATILE
AS $$
DECLARE

    v_business core.businesses%ROWTYPE;
    v_appointment core.appointments%ROWTYPE;
    v_cancellation core.appointment_cancellations%ROWTYPE;

    v_customer core.customers%ROWTYPE;
    v_professional core.professionals%ROWTYPE;

    v_customer_channel core.customer_channels%ROWTYPE;
    v_business_channel core.business_channels%ROWTYPE;

    v_services JSONB;
    v_service_summary TEXT;

    v_timezone TEXT;
    v_local_date TEXT;
    v_local_start TEXT;
    v_local_end TEXT;

    v_offer_rebooking BOOLEAN := FALSE;

    v_rebooking_button_id TEXT;

    v_idempotency_key TEXT;

BEGIN

    -- ========================================================
    -- EMPRESA
    -- ========================================================

    SELECT b.*
    INTO v_business

    FROM core.businesses b

    WHERE b.id = p_business_id

    LIMIT 1;


    IF NOT FOUND
    THEN

        RETURN JSONB_BUILD_OBJECT(
            'ok', FALSE,
            'code', 'BUSINESS_NOT_FOUND'
        );

    END IF;


    v_timezone :=
        COALESCE(
            v_business.timezone,
            'UTC'
        );


    -- ========================================================
    -- APPOINTMENT
    -- ========================================================

    SELECT a.*
    INTO v_appointment

    FROM core.appointments a

    WHERE a.business_id = p_business_id
      AND a.id = p_appointment_id

    LIMIT 1;


    IF NOT FOUND
    THEN

        RETURN JSONB_BUILD_OBJECT(
            'ok', FALSE,
            'code', 'APPOINTMENT_NOT_FOUND'
        );

    END IF;


    IF v_appointment.status <> 'CANCELLED'
    THEN

        RETURN JSONB_BUILD_OBJECT(

            'ok',
                FALSE,

            'code',
                'APPOINTMENT_NOT_CANCELLED',

            'appointment_id',
                v_appointment.id,

            'status',
                v_appointment.status
        );

    END IF;


    -- ========================================================
    -- AUDITORIA DO CANCELAMENTO
    -- ========================================================

    SELECT ac.*
    INTO v_cancellation

    FROM core.appointment_cancellations ac

    WHERE ac.business_id = p_business_id
      AND ac.appointment_id = p_appointment_id

    LIMIT 1;


    IF NOT FOUND
    THEN

        RETURN JSONB_BUILD_OBJECT(
            'ok', FALSE,
            'code', 'APPOINTMENT_CANCELLATION_NOT_FOUND'
        );

    END IF;


    -- ========================================================
    -- IDEMPOTÊNCIA DA NOTIFICAÇÃO
    -- ========================================================

    IF v_cancellation.customer_notification_required IS NOT TRUE
       OR v_cancellation.customer_notification_status = 'NOT_REQUIRED'
    THEN

        RETURN JSONB_BUILD_OBJECT(

            'ok',
                TRUE,

            'code',
                'CANCELLATION_NOTIFICATION_NOT_REQUIRED',

            'appointment_id',
                v_appointment.id,

            'should_send',
                FALSE
        );

    END IF;


    IF v_cancellation.customer_notification_status = 'SENT'
    THEN

        RETURN JSONB_BUILD_OBJECT(

            'ok',
                TRUE,

            'code',
                'CANCELLATION_NOTIFICATION_ALREADY_SENT',

            'appointment_id',
                v_appointment.id,

            'should_send',
                FALSE,

            'message_id',
                v_cancellation.customer_notification_message_id,

            'notified_at',
                v_cancellation.customer_notified_at
        );

    END IF;


    -- ========================================================
    -- CLIENTE
    -- ========================================================

    SELECT c.*
    INTO v_customer

    FROM core.customers c

    WHERE c.business_id = p_business_id
      AND c.id = v_appointment.customer_id

    LIMIT 1;


    IF NOT FOUND
    THEN

        RETURN JSONB_BUILD_OBJECT(
            'ok', FALSE,
            'code', 'CUSTOMER_NOT_FOUND'
        );

    END IF;


    -- ========================================================
    -- PROFISSIONAL
    -- ========================================================

    SELECT p.*
    INTO v_professional

    FROM core.professionals p

    WHERE p.business_id = p_business_id
      AND p.id = v_appointment.professional_id

    LIMIT 1;


    IF NOT FOUND
    THEN

        RETURN JSONB_BUILD_OBJECT(
            'ok', FALSE,
            'code', 'PROFESSIONAL_NOT_FOUND'
        );

    END IF;


    -- ========================================================
    -- WHATSAPP PRINCIPAL DO CLIENTE
    -- ========================================================

    SELECT cc.*
    INTO v_customer_channel

    FROM core.customer_channels cc

    WHERE cc.business_id = p_business_id
      AND cc.customer_id = v_customer.id
      AND cc.channel_type = 'WHATSAPP'
      AND cc.provider = 'META'
      AND cc.active = TRUE

    ORDER BY
        cc.is_primary DESC,
        cc.updated_at DESC,
        cc.created_at DESC

    LIMIT 1;


    IF NOT FOUND
    THEN

        RETURN JSONB_BUILD_OBJECT(

            'ok',
                FALSE,

            'code',
                'CUSTOMER_WHATSAPP_CHANNEL_NOT_FOUND',

            'appointment_id',
                v_appointment.id,

            'customer_id',
                v_customer.id
        );

    END IF;


    -- ========================================================
    -- CANAL META DA EMPRESA
    -- ========================================================

    SELECT bc.*
    INTO v_business_channel

    FROM core.business_channels bc

    WHERE bc.business_id = p_business_id
      AND bc.channel_type = 'WHATSAPP'
      AND bc.provider = 'META'
      AND bc.status = 'ACTIVE'

    ORDER BY
        bc.updated_at DESC,
        bc.created_at DESC

    LIMIT 1;


    IF NOT FOUND
    THEN

        RETURN JSONB_BUILD_OBJECT(

            'ok',
                FALSE,

            'code',
                'BUSINESS_WHATSAPP_CHANNEL_NOT_FOUND',

            'appointment_id',
                v_appointment.id
        );

    END IF;


    -- ========================================================
    -- SERVIÇOS DO APPOINTMENT
    --
    -- Usa snapshot histórico, não o cadastro atual do serviço.
    -- ========================================================

    SELECT

        COALESCE(
            JSONB_AGG(
                JSONB_BUILD_OBJECT(

                    'service_id',
                        ai.service_id,

                    'name',
                        ai.service_name_snapshot,

                    'price',
                        ai.price_snapshot,

                    'duration_minutes',
                        ai.duration_minutes_snapshot,

                    'quantity',
                        ai.quantity

                )
                ORDER BY ai.display_order
            ),
            '[]'::JSONB
        ),

        COALESCE(
            STRING_AGG(
                ai.service_name_snapshot,
                ' + '
                ORDER BY ai.display_order
            ),
            'Atendimento'
        )

    INTO
        v_services,
        v_service_summary

    FROM core.appointment_items ai

    WHERE ai.business_id = p_business_id
      AND ai.appointment_id = p_appointment_id;


    -- ========================================================
    -- DATA/HORA LOCAL
    -- ========================================================

    v_local_date :=
        TO_CHAR(
            v_appointment.start_at
                AT TIME ZONE v_timezone,
            'DD/MM/YYYY'
        );


    v_local_start :=
        TO_CHAR(
            v_appointment.start_at
                AT TIME ZONE v_timezone,
            'HH24:MI'
        );


    v_local_end :=
        TO_CHAR(
            v_appointment.end_at
                AT TIME ZONE v_timezone,
            'HH24:MI'
        );


    -- ========================================================
    -- REAGENDAMENTO
    -- ========================================================

    v_offer_rebooking :=
        v_cancellation.actor_type IN (
            'PROFESSIONAL',
            'BUSINESS'
        );


    IF v_offer_rebooking
    THEN

        v_rebooking_button_id :=
            'rebook|'
            ||
            v_appointment.id::TEXT;

    ELSE

        v_rebooking_button_id :=
            NULL;

    END IF;


    -- ========================================================
    -- IDEMPOTENCY KEY
    -- ========================================================

    v_idempotency_key :=
        'CANCEL_NOTICE:'
        ||
        v_cancellation.id::TEXT;


    -- ========================================================
    -- RETORNO
    -- ========================================================

    RETURN JSONB_BUILD_OBJECT(

        'ok',
            TRUE,

        'code',
            'CANCELLATION_NOTIFICATION_READY',

        'should_send',
            TRUE,

        'idempotency_key',
            v_idempotency_key,


        -- ====================================================
        -- IDENTIDADE
        -- ====================================================

        'business',
            JSONB_BUILD_OBJECT(

                'business_id',
                    v_business.id,

                'business_code',
                    v_business.business_code,

                'name',
                    v_business.name,

                'timezone',
                    v_timezone,

                'locale',
                    v_business.locale
            ),


        'customer',
            JSONB_BUILD_OBJECT(

                'customer_id',
                    v_customer.id,

                'name',
                    v_customer.name,

                'customer_channel_id',
                    v_customer_channel.id,

                'recipient',
                    v_customer_channel.external_user_id,

                'display_address',
                    v_customer_channel.display_address
            ),


        'professional',
            JSONB_BUILD_OBJECT(

                'professional_id',
                    v_professional.id,

                'professional_code',
                    v_professional.professional_code,

                'name',
                    COALESCE(
                        v_professional.display_name,
                        v_professional.name
                    )
            ),


        -- ====================================================
        -- CANAL DE SAÍDA
        -- ====================================================

        'channel',
            JSONB_BUILD_OBJECT(

                'business_channel_id',
                    v_business_channel.id,

                'channel_type',
                    'WHATSAPP',

                'provider',
                    'META',

                'phone_number_id',
                    v_business_channel.external_channel_id
            ),


        -- ====================================================
        -- AGENDAMENTO
        -- ====================================================

        'appointment',
            JSONB_BUILD_OBJECT(

                'appointment_id',
                    v_appointment.id,

                'status',
                    v_appointment.status,

                'start_at',
                    v_appointment.start_at,

                'end_at',
                    v_appointment.end_at,

                'local_date',
                    v_local_date,

                'local_start',
                    v_local_start,

                'local_end',
                    v_local_end,

                'total_price',
                    v_appointment.total_price,

                'currency',
                    v_appointment.currency,

                'services',
                    v_services,

                'service_summary',
                    v_service_summary
            ),


        -- ====================================================
        -- CANCELAMENTO
        -- ====================================================

        'cancellation',
            JSONB_BUILD_OBJECT(

                'cancellation_id',
                    v_cancellation.id,

                'actor_type',
                    v_cancellation.actor_type,

                'public_reason',
                    v_cancellation.public_reason,

                'cancelled_at',
                    v_cancellation.cancelled_at,

                'notification_status',
                    v_cancellation.customer_notification_status

                -- internal_reason propositalmente NÃO retorna.
            ),


        -- ====================================================
        -- UX
        -- ====================================================

        'rebooking',
            JSONB_BUILD_OBJECT(

                'enabled',
                    v_offer_rebooking,

                'button_id',
                    v_rebooking_button_id,

                'button_text',
                    CASE
                        WHEN v_offer_rebooking
                            THEN 'Ver outros horários'
                        ELSE NULL
                    END
            )
    );

END;
$$;