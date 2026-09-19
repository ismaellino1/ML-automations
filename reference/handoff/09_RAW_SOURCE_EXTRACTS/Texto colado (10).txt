CREATE OR REPLACE FUNCTION core.get_assistant_context(
    p_business_code TEXT,
    p_channel_type TEXT,
    p_provider TEXT,
    p_external_user_id TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_business          core.businesses%ROWTYPE;
    v_business_channel  core.business_channels%ROWTYPE;
    v_customer_channel  core.customer_channels%ROWTYPE;
    v_customer          core.customers%ROWTYPE;
    v_conversation      core.conversations%ROWTYPE;
BEGIN

    -- =========================================================
    -- BUSINESS
    -- =========================================================

    SELECT *
    INTO v_business
    FROM core.businesses b
    WHERE b.business_code = p_business_code
      AND b.status = 'ACTIVE'
    LIMIT 1;

    IF v_business.id IS NULL THEN
        RETURN JSONB_BUILD_OBJECT(
            'ok', FALSE,
            'code', 'BUSINESS_NOT_FOUND',
            'business_code', p_business_code
        );
    END IF;


    -- =========================================================
    -- BUSINESS CHANNEL
    -- =========================================================

    SELECT *
    INTO v_business_channel
    FROM core.business_channels bc
    WHERE bc.business_id = v_business.id
      AND bc.channel_type = p_channel_type
      AND bc.provider = p_provider
      AND bc.status = 'ACTIVE'
    ORDER BY bc.created_at DESC
    LIMIT 1;


    -- =========================================================
    -- CUSTOMER CHANNEL + CUSTOMER
    -- =========================================================

    IF NULLIF(p_external_user_id, '') IS NOT NULL THEN

        SELECT *
        INTO v_customer_channel
        FROM core.customer_channels cc
        WHERE cc.business_id = v_business.id
          AND cc.channel_type = p_channel_type
          AND cc.provider = p_provider
          AND cc.external_user_id = p_external_user_id
          AND cc.active = TRUE
        ORDER BY
            cc.is_primary DESC,
            cc.created_at DESC
        LIMIT 1;

    END IF;


    IF v_customer_channel.customer_id IS NOT NULL THEN

        SELECT *
        INTO v_customer
        FROM core.customers c
        WHERE c.id = v_customer_channel.customer_id
          AND c.business_id = v_business.id
        LIMIT 1;

    END IF;


    -- =========================================================
    -- OPEN CONVERSATION
    -- =========================================================

    IF v_customer.id IS NOT NULL THEN

        SELECT *
        INTO v_conversation
        FROM core.conversations c
        WHERE c.business_id = v_business.id
          AND c.customer_id = v_customer.id
          AND c.status = 'OPEN'
        ORDER BY
            c.last_message_at DESC NULLS LAST,
            c.created_at DESC
        LIMIT 1;

    END IF;


    -- =========================================================
    -- RESULT
    -- =========================================================

    RETURN JSONB_BUILD_OBJECT(

        'ok',
            TRUE,

        'loaded_at',
            NOW(),

        'clock',
            JSONB_BUILD_OBJECT(
                'timezone',
                    v_business.timezone,

                'local_datetime',
                    TO_CHAR(
                        NOW() AT TIME ZONE v_business.timezone,
                        'YYYY-MM-DD HH24:MI:SS'
                    ),

                'local_date',
                    TO_CHAR(
                        NOW() AT TIME ZONE v_business.timezone,
                        'YYYY-MM-DD'
                    ),

                'local_time',
                    TO_CHAR(
                        NOW() AT TIME ZONE v_business.timezone,
                        'HH24:MI'
                    )
            ),


        -- =====================================================
        -- BUSINESS
        -- =====================================================

        'business',
            JSONB_BUILD_OBJECT(
                'id',
                    v_business.id,

                'code',
                    v_business.business_code,

                'name',
                    v_business.name,

                'timezone',
                    v_business.timezone,

                'locale',
                    v_business.locale,

                'plan_code',
                    v_business.plan_code
            ),


        -- =====================================================
        -- CHANNEL
        -- =====================================================

        'channel',
            CASE
                WHEN v_business_channel.id IS NULL THEN NULL
                ELSE JSONB_BUILD_OBJECT(
                    'id',
                        v_business_channel.id,

                    'channel_type',
                        v_business_channel.channel_type,

                    'provider',
                        v_business_channel.provider,

                    'external_channel_id',
                        v_business_channel.external_channel_id,

                    'external_account_id',
                        v_business_channel.external_account_id,

                    'sender_address',
                        v_business_channel.sender_address,

                    'credential_key',
                        v_business_channel.credential_key,

                    'metadata',
                        COALESCE(
                            v_business_channel.metadata,
                            '{}'::JSONB
                        )
                )
            END,


        -- =====================================================
        -- BUSINESS CONFIGURATION
        -- =====================================================

        'settings',
            COALESCE(
                (
                    SELECT
                        TO_JSONB(bs)
                        - 'id'
                        - 'business_id'
                        - 'created_at'
                        - 'updated_at'
                    FROM core.business_settings bs
                    WHERE bs.business_id = v_business.id
                    LIMIT 1
                ),
                '{}'::JSONB
            ),

        'ai_settings',
            COALESCE(
                (
                    SELECT
                        TO_JSONB(ai)
                        - 'id'
                        - 'business_id'
                        - 'created_at'
                        - 'updated_at'
                    FROM core.business_ai_settings ai
                    WHERE ai.business_id = v_business.id
                    LIMIT 1
                ),
                '{}'::JSONB
            ),

        'brand',
            COALESCE(
                (
                    SELECT
                        TO_JSONB(bp)
                        - 'id'
                        - 'business_id'
                        - 'created_at'
                        - 'updated_at'
                    FROM core.business_brand_profiles bp
                    WHERE bp.business_id = v_business.id
                    LIMIT 1
                ),
                '{}'::JSONB
            ),


        -- =====================================================
        -- CUSTOMER
        -- =====================================================

        'customer',
            CASE
                WHEN v_customer.id IS NULL THEN
                    JSONB_BUILD_OBJECT(
                        'exists', FALSE,
                        'external_user_id', p_external_user_id
                    )

                ELSE
                    JSONB_BUILD_OBJECT(
                        'exists',
                            TRUE,

                        'id',
                            v_customer.id,

                        'name',
                            v_customer.name,

                        'status',
                            v_customer.status,

                        'channel_id',
                            v_customer_channel.id,

                        'external_user_id',
                            v_customer_channel.external_user_id,

                        'display_address',
                            v_customer_channel.display_address,

                        'preferences',
                            COALESCE(
                                (
                                    SELECT
                                        TO_JSONB(cp)
                                        - 'id'
                                        - 'business_id'
                                        - 'customer_id'
                                        - 'created_at'
                                        - 'updated_at'
                                    FROM core.customer_preferences cp
                                    WHERE cp.business_id = v_business.id
                                      AND cp.customer_id = v_customer.id
                                    LIMIT 1
                                ),
                                '{}'::JSONB
                            ),

                        'communication_profile',
                            COALESCE(
                                (
                                    SELECT
                                        TO_JSONB(ccp)
                                        - 'id'
                                        - 'business_id'
                                        - 'customer_id'
                                        - 'created_at'
                                        - 'updated_at'
                                    FROM core.customer_communication_profiles ccp
                                    WHERE ccp.business_id = v_business.id
                                      AND ccp.customer_id = v_customer.id
                                    LIMIT 1
                                ),
                                '{}'::JSONB
                            )
                    )
            END,


        -- =====================================================
        -- CONVERSATION
        -- =====================================================

        'conversation',
            CASE
                WHEN v_conversation.id IS NULL THEN
                    JSONB_BUILD_OBJECT(
                        'exists', FALSE
                    )

                ELSE
                    JSONB_BUILD_OBJECT(
                        'exists',
                            TRUE,

                        'id',
                            v_conversation.id,

                        'status',
                            v_conversation.status,

                        'automation_mode',
                            v_conversation.automation_mode,

                        'current_intent',
                            v_conversation.current_intent,

                        'pending_action',
                            v_conversation.pending_action,

                        'context',
                            COALESCE(
                                v_conversation.context,
                                '{}'::JSONB
                            ),

                        'slots',
                            COALESCE(
                                v_conversation.slots,
                                '{}'::JSONB
                            ),

                        'context_summary',
                            v_conversation.context_summary,

                        'version',
                            v_conversation.version,

                        'last_message_at',
                            v_conversation.last_message_at,

                        'session_expires_at',
                            v_conversation.session_expires_at
                    )
            END,


        -- =====================================================
        -- SERVICES
        -- =====================================================

        'services',
            COALESCE(
                (
                    SELECT JSONB_AGG(service_data ORDER BY display_order)

                    FROM (
                        SELECT
                            s.display_order,

                            JSONB_BUILD_OBJECT(
                                'service_id',
                                    s.id,

                                'service_code',
                                    s.service_code,

                                'name',
                                    s.name,

                                'description',
                                    s.description,

                                'price',
                                    s.price,

                                'currency',
                                    s.currency,

                                'duration_minutes',
                                    s.duration_minutes,

                                'buffer_before_minutes',
                                    s.buffer_before_minutes,

                                'buffer_after_minutes',
                                    s.buffer_after_minutes,

                                'professionals',
                                    COALESCE(
                                        (
                                            SELECT JSONB_AGG(
                                                JSONB_BUILD_OBJECT(
                                                    'professional_id',
                                                        p.id,

                                                    'professional_code',
                                                        p.professional_code,

                                                    'name',
                                                        p.name,

                                                    'display_name',
                                                        p.display_name,

                                                    'description',
                                                        p.description,

                                                    'effective_price',
                                                        COALESCE(
                                                            ps.price_override,
                                                            s.price
                                                        ),

                                                    'effective_duration_minutes',
                                                        COALESCE(
                                                            ps.duration_minutes_override,
                                                            s.duration_minutes
                                                        ),

                                                    'calendar_provider',
                                                        p.calendar_provider,

                                                    'external_calendar_id',
                                                        p.external_calendar_id
                                                )
                                                ORDER BY p.display_order
                                            )

                                            FROM core.professional_services ps

                                            JOIN core.professionals p
                                                ON p.id = ps.professional_id

                                            WHERE ps.business_id = v_business.id
                                              AND ps.service_id = s.id
                                              AND ps.active = TRUE
                                              AND ps.online_booking_enabled = TRUE
                                              AND p.active = TRUE
                                              AND p.online_booking_enabled = TRUE
                                        ),
                                        '[]'::JSONB
                                    )
                            ) AS service_data

                        FROM core.services s

                        WHERE s.business_id = v_business.id
                          AND s.active = TRUE
                          AND s.online_booking_enabled = TRUE
                    ) service_rows
                ),
                '[]'::JSONB
            ),


        -- =====================================================
        -- PROFESSIONALS
        -- =====================================================

        'professionals',
            COALESCE(
                (
                    SELECT JSONB_AGG(
                        JSONB_BUILD_OBJECT(
                            'professional_id',
                                p.id,

                            'professional_code',
                                p.professional_code,

                            'name',
                                p.name,

                            'display_name',
                                p.display_name,

                            'description',
                                p.description,

                            'calendar_provider',
                                p.calendar_provider,

                            'external_calendar_id',
                                p.external_calendar_id
                        )
                        ORDER BY p.display_order
                    )

                    FROM core.professionals p

                    WHERE p.business_id = v_business.id
                      AND p.active = TRUE
                      AND p.online_booking_enabled = TRUE
                ),
                '[]'::JSONB
            ),


        -- =====================================================
        -- CURRENT ACTIVE SLOT OFFER
        -- =====================================================

        'active_offer',
            CASE

                WHEN v_conversation.id IS NULL THEN NULL

                ELSE (
                    SELECT JSONB_BUILD_OBJECT(
                        'slot_offer_id',
                            so.id,

                        'status',
                            so.status,

                        'expires_at',
                            so.expires_at,

                        'date_from',
                            so.date_from,

                        'date_until',
                            so.date_until,

                        'time_from',
                            so.time_from,

                        'time_until',
                            so.time_until,

                        'requested_service_ids',
                            so.requested_service_ids,

                        'requested_professional_id',
                            so.requested_professional_id,

                        'option_count',
                            so.option_count,

                        'options',
                            COALESCE(
                                (
                                    SELECT JSONB_AGG(
                                        JSONB_BUILD_OBJECT(
                                            'option_number',
                                                soo.option_number,

                                            'professional_id',
                                                soo.professional_id,

                                            'professional_name',
                                                soo.professional_name_snapshot,

                                            'start_at',
                                                soo.start_at,

                                            'end_at',
                                                soo.end_at,

                                            'local_date',
                                                TO_CHAR(
                                                    soo.start_at
                                                    AT TIME ZONE v_business.timezone,
                                                    'YYYY-MM-DD'
                                                ),

                                            'local_start',
                                                TO_CHAR(
                                                    soo.start_at
                                                    AT TIME ZONE v_business.timezone,
                                                    'HH24:MI'
                                                ),

                                            'local_end',
                                                TO_CHAR(
                                                    soo.end_at
                                                    AT TIME ZONE v_business.timezone,
                                                    'HH24:MI'
                                                ),

                                            'total_price',
                                                soo.total_price,

                                            'currency',
                                                soo.currency,

                                            'total_service_minutes',
                                                soo.total_service_minutes
                                        )
                                        ORDER BY soo.option_number
                                    )

                                    FROM core.slot_offer_options soo
                                    WHERE soo.slot_offer_id = so.id
                                ),
                                '[]'::JSONB
                            )
                    )

                    FROM core.slot_offers so

                    WHERE so.business_id = v_business.id
                      AND so.conversation_id = v_conversation.id
                      AND so.status = 'ACTIVE'
                      AND so.expires_at > NOW()
                      AND so.selected_option_number IS NULL

                    ORDER BY so.created_at DESC
                    LIMIT 1
                )

            END,


        -- =====================================================
        -- CUSTOMER APPOINTMENTS
        -- =====================================================

        'appointments',
            CASE

                WHEN v_customer.id IS NULL THEN
                    '[]'::JSONB

                ELSE
                    COALESCE(
                        (
                            SELECT JSONB_AGG(appointment_data ORDER BY start_at)

                            FROM (
                                SELECT
                                    a.start_at,

                                    JSONB_BUILD_OBJECT(
                                        'appointment_id',
                                            a.id,

                                        'status',
                                            a.status,

                                        'professional_id',
                                            a.professional_id,

                                        'professional_name',
                                            p.name,

                                        'start_at',
                                            a.start_at,

                                        'end_at',
                                            a.end_at,

                                        'local_date',
                                            TO_CHAR(
                                                a.start_at
                                                AT TIME ZONE v_business.timezone,
                                                'YYYY-MM-DD'
                                            ),

                                        'local_start',
                                            TO_CHAR(
                                                a.start_at
                                                AT TIME ZONE v_business.timezone,
                                                'HH24:MI'
                                            ),

                                        'local_end',
                                            TO_CHAR(
                                                a.end_at
                                                AT TIME ZONE v_business.timezone,
                                                'HH24:MI'
                                            ),

                                        'total_price',
                                            a.total_price,

                                        'currency',
                                            a.currency,

                                        'total_service_minutes',
                                            a.total_service_minutes,

                                        'hold_expires_at',
                                            a.hold_expires_at,

                                        'confirmed_at',
                                            a.confirmed_at,

                                        'cancelled_at',
                                            a.cancelled_at,

                                        'metadata',
                                            COALESCE(
                                                a.metadata,
                                                '{}'::JSONB
                                            )
                                    ) AS appointment_data

                                FROM core.appointments a

                                LEFT JOIN core.professionals p
                                    ON p.id = a.professional_id

                                WHERE a.business_id = v_business.id
                                  AND a.customer_id = v_customer.id
                                  AND a.end_at >= NOW() - INTERVAL '24 hours'

                                ORDER BY a.start_at
                                LIMIT 10

                            ) appointment_rows
                        ),
                        '[]'::JSONB
                    )

            END

    );

END;
$$;