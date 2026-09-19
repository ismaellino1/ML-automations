-- 051_whatsapp_calendar_hardening.sql
-- Production-grade WhatsApp rendering, delivery receipts and Calendar job enrichment.


-- Delivery/campaign columns are created here because delivery functions below
-- reference them. Migration 052 repeats these ADD COLUMN IF NOT EXISTS guards
-- intentionally so fresh installs and upgrades remain order-safe.
ALTER TABLE core.campaign_recipients
    ADD COLUMN IF NOT EXISTS outbound_message_id UUID,
    ADD COLUMN IF NOT EXISTS sent_at TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS delivered_at TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS read_at TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS converted_at TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS attributed_appointment_id UUID,
    ADD COLUMN IF NOT EXISTS failure_reason TEXT;

CREATE TABLE IF NOT EXISTS core.message_delivery_events (
    id BIGSERIAL PRIMARY KEY,
    business_id UUID NOT NULL,
    message_id UUID NOT NULL,
    provider VARCHAR(50) NOT NULL,
    external_message_id TEXT,
    delivery_status VARCHAR(30) NOT NULL,
    provider_timestamp TIMESTAMPTZ,
    payload JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT fk_delivery_event_message
        FOREIGN KEY (business_id, message_id)
        REFERENCES core.messages(business_id, id)
        ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_message_delivery_events_external
ON core.message_delivery_events(business_id, provider, external_message_id, created_at DESC);

CREATE OR REPLACE FUNCTION core.build_whatsapp_payload_v3(
    p_recipient TEXT,
    p_text TEXT,
    p_response_type TEXT DEFAULT 'GENERAL',
    p_execution JSONB DEFAULT '{}'::jsonb,
    p_extra JSONB DEFAULT '{}'::jsonb
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
AS $function$
DECLARE
    v_type TEXT := upper(coalesce(p_response_type, 'GENERAL'));
    v_result JSONB := coalesce(p_execution -> 'result', '{}'::jsonb);
    v_slots JSONB := coalesce(v_result -> 'slots', '[]'::jsonb);
    v_offer_id TEXT := nullif(v_result ->> 'slot_offer_id', '');
    v_count INTEGER := jsonb_array_length(v_slots);
    v_buttons JSONB;
    v_rows JSONB;
    v_template_name TEXT := nullif(p_extra ->> 'template_name', '');
    v_template_language TEXT := coalesce(nullif(p_extra ->> 'template_language', ''), 'pt_BR');
    v_rebook_id TEXT := nullif(p_extra ->> 'rebook_appointment_id', '');
BEGIN
    IF nullif(btrim(p_recipient), '') IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'code', 'RECIPIENT_REQUIRED');
    END IF;

    -- Approved Meta template. Used for proactive messages outside the 24h window.
    IF v_template_name IS NOT NULL THEN
        RETURN jsonb_build_object(
            'messaging_product', 'whatsapp',
            'recipient_type', 'individual',
            'to', p_recipient,
            'type', 'template',
            'template', jsonb_strip_nulls(jsonb_build_object(
                'name', v_template_name,
                'language', jsonb_build_object('code', v_template_language),
                'components', CASE
                    WHEN jsonb_typeof(p_extra -> 'template_components') = 'array'
                        THEN p_extra -> 'template_components'
                    ELSE NULL
                END
            ))
        );
    END IF;

    -- Cancellation by business/professional can offer a deterministic rebooking action.
    IF v_rebook_id IS NOT NULL THEN
        RETURN jsonb_build_object(
            'messaging_product', 'whatsapp',
            'recipient_type', 'individual',
            'to', p_recipient,
            'type', 'interactive',
            'interactive', jsonb_build_object(
                'type', 'button',
                'body', jsonb_build_object('text', left(coalesce(p_text, ''), 1024)),
                'action', jsonb_build_object('buttons', jsonb_build_array(
                    jsonb_build_object(
                        'type', 'reply',
                        'reply', jsonb_build_object(
                            'id', 'rebook|' || v_rebook_id,
                            'title', left(coalesce(nullif(p_extra ->> 'rebook_button_text', ''), 'Ver outros horários'), 20)
                        )
                    )
                ))
            )
        );
    END IF;

    -- Slot offer <= 3: buttons are faster and require fewer taps.
    IF v_type = 'SLOT_OPTIONS' AND v_offer_id IS NOT NULL AND v_count BETWEEN 1 AND 3 THEN
        SELECT jsonb_agg(
            jsonb_build_object(
                'type', 'reply',
                'reply', jsonb_build_object(
                    'id', 'slot|' || v_offer_id || '|' || ordinality,
                    'title', left(coalesce(slot ->> 'local_start', 'Opção ' || ordinality), 20)
                )
            ) ORDER BY ordinality
        )
        INTO v_buttons
        FROM jsonb_array_elements(v_slots) WITH ORDINALITY AS x(slot, ordinality);

        RETURN jsonb_build_object(
            'messaging_product', 'whatsapp',
            'recipient_type', 'individual',
            'to', p_recipient,
            'type', 'interactive',
            'interactive', jsonb_build_object(
                'type', 'button',
                'body', jsonb_build_object('text', left(coalesce(p_text, 'Escolha um horário:'), 1024)),
                'action', jsonb_build_object('buttons', v_buttons)
            )
        );
    END IF;

    -- Slot offer 4..10: a list keeps the message readable.
    IF v_type = 'SLOT_OPTIONS' AND v_offer_id IS NOT NULL AND v_count BETWEEN 4 AND 10 THEN
        SELECT jsonb_agg(
            jsonb_build_object(
                'id', 'slot|' || v_offer_id || '|' || ordinality,
                'title', left(
                    coalesce(slot ->> 'local_start', 'Opção ' || ordinality)
                    || CASE WHEN nullif(slot ->> 'professional_name', '') IS NOT NULL
                            THEN ' · ' || (slot ->> 'professional_name') ELSE '' END,
                    24
                ),
                'description', left(
                    trim(both ' ·' from concat_ws(' · ',
                        CASE WHEN nullif(slot ->> 'local_date', '') IS NOT NULL THEN slot ->> 'local_date' END,
                        CASE WHEN nullif(slot ->> 'total_price', '') IS NOT NULL
                             THEN 'R$ ' || replace((slot ->> 'total_price'), '.', ',') END
                    )),
                    72
                )
            ) ORDER BY ordinality
        )
        INTO v_rows
        FROM jsonb_array_elements(v_slots) WITH ORDINALITY AS x(slot, ordinality);

        RETURN jsonb_build_object(
            'messaging_product', 'whatsapp',
            'recipient_type', 'individual',
            'to', p_recipient,
            'type', 'interactive',
            'interactive', jsonb_build_object(
                'type', 'list',
                'body', jsonb_build_object('text', left(coalesce(p_text, 'Escolha um horário:'), 1024)),
                'action', jsonb_build_object(
                    'button', 'Ver horários',
                    'sections', jsonb_build_array(jsonb_build_object('title', 'Horários disponíveis', 'rows', v_rows))
                )
            )
        );
    END IF;

    RETURN jsonb_build_object(
        'messaging_product', 'whatsapp',
        'recipient_type', 'individual',
        'to', p_recipient,
        'type', 'text',
        'text', jsonb_build_object('preview_url', false, 'body', left(coalesce(p_text, ''), 4096))
    );
END;
$function$;

CREATE OR REPLACE FUNCTION core.queue_outbound_notification_v3(
    p_business_id UUID,
    p_customer_id UUID,
    p_notification_type TEXT,
    p_content JSONB,
    p_dedupe_key TEXT,
    p_execution_ref TEXT,
    p_execution JSONB DEFAULT '{}'::jsonb,
    p_response_type TEXT DEFAULT 'GENERAL'
)
RETURNS JSONB
LANGUAGE plpgsql
VOLATILE
AS $function$
DECLARE
    v_customer_channel core.customer_channels%ROWTYPE;
    v_business_channel core.business_channels%ROWTYPE;
    v_conversation core.conversations%ROWTYPE;
    v_registered JSONB;
    v_message_id UUID;
    v_should_send BOOLEAN;
    v_session_open BOOLEAN := false;
    v_text TEXT;
    v_meta JSONB;
    v_message_type TEXT;
    v_job_id UUID;
    v_extra JSONB := coalesce(p_content, '{}'::jsonb);
BEGIN
    IF nullif(btrim(p_dedupe_key), '') IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'code', 'IDEMPOTENCY_KEY_REQUIRED');
    END IF;

    SELECT * INTO v_customer_channel
    FROM core.customer_channels cc
    WHERE cc.business_id = p_business_id
      AND cc.customer_id = p_customer_id
      AND cc.channel_type = 'WHATSAPP'
      AND cc.provider = 'META'
      AND cc.active = true
    ORDER BY cc.is_primary DESC, cc.updated_at DESC
    LIMIT 1;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('ok', false, 'code', 'CUSTOMER_WHATSAPP_CHANNEL_NOT_FOUND');
    END IF;

    SELECT * INTO v_business_channel
    FROM core.business_channels bc
    WHERE bc.business_id = p_business_id
      AND bc.channel_type = 'WHATSAPP'
      AND bc.provider = 'META'
      AND bc.status = 'ACTIVE'
    ORDER BY bc.updated_at DESC
    LIMIT 1;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('ok', false, 'code', 'BUSINESS_WHATSAPP_CHANNEL_NOT_FOUND');
    END IF;

    SELECT * INTO v_conversation
    FROM core.conversations c
    WHERE c.business_id = p_business_id
      AND c.customer_id = p_customer_id
      AND c.business_channel_id = v_business_channel.id
      AND c.customer_channel_id = v_customer_channel.id
      AND c.status = 'OPEN'
    ORDER BY c.last_message_at DESC NULLS LAST, c.created_at DESC
    LIMIT 1
    FOR UPDATE;

    IF NOT FOUND THEN
        BEGIN
            INSERT INTO core.conversations(
                business_id, customer_id, business_channel_id, customer_channel_id,
                status, automation_mode, opened_at, last_message_at
            ) VALUES (
                p_business_id, p_customer_id, v_business_channel.id, v_customer_channel.id,
                'OPEN', 'AUTO', now(), now()
            ) RETURNING * INTO v_conversation;
        EXCEPTION WHEN unique_violation THEN
            SELECT * INTO v_conversation
            FROM core.conversations c
            WHERE c.business_id = p_business_id
              AND c.business_channel_id = v_business_channel.id
              AND c.customer_channel_id = v_customer_channel.id
              AND c.status = 'OPEN'
            ORDER BY c.created_at DESC LIMIT 1;
        END;
    END IF;

    v_session_open := v_conversation.last_inbound_at IS NOT NULL
                      AND now() <= v_conversation.last_inbound_at + interval '24 hours';

    v_text := coalesce(nullif(p_content ->> 'text', ''), 'Temos uma atualização para você.');

    -- Outside the customer-service window, free-form proactive messages are not sent.
    IF NOT v_session_open AND nullif(p_content ->> 'template_name', '') IS NULL THEN
        RETURN jsonb_build_object(
            'ok', true,
            'code', 'WHATSAPP_TEMPLATE_REQUIRED',
            'should_send', false,
            'notification_type', p_notification_type,
            'conversation_id', v_conversation.id
        );
    END IF;

    v_meta := core.build_whatsapp_payload_v3(
        v_customer_channel.external_user_id,
        v_text,
        p_response_type,
        coalesce(p_execution, '{}'::jsonb),
        v_extra
    );

    v_message_type := CASE coalesce(v_meta ->> 'type', 'text')
        WHEN 'interactive' THEN 'INTERACTIVE'
        WHEN 'template' THEN 'TEMPLATE'
        ELSE 'TEXT'
    END;

    v_registered := core.register_outbound_message(
        p_business_id,
        v_conversation.id,
        p_customer_id,
        v_customer_channel.id,
        'WHATSAPP',
        'META',
        p_dedupe_key,
        v_text,
        v_message_type,
        NULL,
        jsonb_build_object(
            'notification_type', p_notification_type,
            'response_type', p_response_type,
            'meta_payload', v_meta,
            'metadata', coalesce(p_content -> 'metadata', '{}'::jsonb),
            'execution_ref', p_execution_ref
        )
    );

    IF coalesce((v_registered ->> 'ok')::boolean, false) IS NOT TRUE THEN
        RETURN v_registered || jsonb_build_object('code', 'OUTBOUND_REGISTRATION_FAILED');
    END IF;

    v_message_id := nullif(v_registered ->> 'message_id', '')::uuid;
    v_should_send := coalesce((v_registered ->> 'should_send')::boolean, false);

    IF NOT v_should_send THEN
        RETURN jsonb_build_object(
            'ok', true,
            'code', 'OUTBOUND_ALREADY_REGISTERED',
            'should_send', false,
            'internal_message_id', v_message_id
        );
    END IF;

    v_job_id := core.enqueue_integration_job_v1(
        p_business_id,
        'WHATSAPP_OUTBOUND',
        'SEND',
        jsonb_build_object(
            'internal_message_id', v_message_id,
            'phone_number_id', v_business_channel.external_channel_id,
            'recipient', v_customer_channel.external_user_id,
            'graph_api_version', coalesce(v_business_channel.metadata ->> 'graph_api_version', 'v26.0'),
            'meta_payload', v_meta,
            'notification_type', p_notification_type,
            'campaign_recipient_id', nullif(p_content ->> 'campaign_recipient_id', '')
        ),
        p_dedupe_key,
        'MESSAGE',
        v_message_id,
        100,
        8,
        now(),
        p_execution_ref,
        NULL
    );

    RETURN jsonb_build_object(
        'ok', true,
        'code', 'OUTBOUND_QUEUED',
        'should_send', true,
        'job_id', v_job_id,
        'internal_message_id', v_message_id,
        'delivery_mode', coalesce(v_meta ->> 'type', 'text')
    );
END;
$function$;

-- Compatibility wrapper used by previous migrations/workflows.
CREATE OR REPLACE FUNCTION core.queue_outbound_notification_v1(
    p_business_id UUID,
    p_customer_id UUID,
    p_notification_type TEXT,
    p_content JSONB,
    p_dedupe_key TEXT,
    p_execution_ref TEXT
)
RETURNS JSONB
LANGUAGE sql
VOLATILE
AS $function$
SELECT core.queue_outbound_notification_v3(
    p_business_id,p_customer_id,p_notification_type,p_content,p_dedupe_key,p_execution_ref,
    '{}'::jsonb,coalesce(p_content->>'response_type','GENERAL')
);
$function$;

CREATE OR REPLACE FUNCTION core.claim_outbound_delivery_batch(p_limit INTEGER,p_worker_ref TEXT)
RETURNS TABLE(job JSONB)
LANGUAGE sql
VOLATILE
AS $function$
SELECT jsonb_build_object(
    'job_id', j.id,
    'business_id', j.business_id,
    'internal_message_id', j.payload ->> 'internal_message_id',
    'phone_number_id', j.payload ->> 'phone_number_id',
    'recipient', j.payload ->> 'recipient',
    'graph_api_version', coalesce(j.payload ->> 'graph_api_version','v26.0'),
    'meta_payload', j.payload -> 'meta_payload',
    'notification_type', j.payload ->> 'notification_type',
    'campaign_recipient_id', j.payload ->> 'campaign_recipient_id'
)
FROM core.claim_integration_jobs_v1('WHATSAPP_OUTBOUND',p_limit,p_worker_ref,120) q(job)
JOIN LATERAL jsonb_to_record(q.job) AS claimed(id uuid) ON true
JOIN core.integration_jobs j ON j.id=claimed.id;
$function$;

CREATE OR REPLACE FUNCTION core.complete_outbound_delivery(
    p_job_id UUID,p_external_message_id TEXT,p_provider_response JSONB
)
RETURNS JSONB
LANGUAGE plpgsql
VOLATILE
AS $function$
DECLARE
    v_job core.integration_jobs%ROWTYPE;
    v_message_id UUID;
    v_campaign_recipient UUID;
    v_bind JSONB;
    v_done JSONB;
BEGIN
    SELECT * INTO v_job FROM core.integration_jobs WHERE id=p_job_id FOR UPDATE;
    IF NOT FOUND THEN RETURN jsonb_build_object('ok',false,'code','JOB_NOT_FOUND'); END IF;

    v_message_id := nullif(v_job.payload ->> 'internal_message_id','')::uuid;
    v_campaign_recipient := nullif(v_job.payload ->> 'campaign_recipient_id','')::uuid;

    IF v_message_id IS NOT NULL AND nullif(p_external_message_id,'') IS NOT NULL THEN
        v_bind := core.bind_outbound_external_message(
            v_job.business_id,v_message_id,'META',p_external_message_id
        );
        UPDATE core.messages
        SET delivery_status='SENT', sent_at=coalesce(sent_at,now()), updated_at=now()
        WHERE business_id=v_job.business_id AND id=v_message_id;
    END IF;

    IF v_campaign_recipient IS NOT NULL THEN
        UPDATE core.campaign_recipients
        SET status='SENT', sent_at=coalesce(sent_at,now()), updated_at=now()
        WHERE id=v_campaign_recipient AND business_id=v_job.business_id;
    END IF;

    v_done := core.complete_integration_job_v1(
        p_job_id,
        coalesce(p_provider_response,'{}'::jsonb)
          || jsonb_build_object('external_message_id',p_external_message_id,'binding',v_bind)
    );
    RETURN v_done;
END;
$function$;

CREATE OR REPLACE FUNCTION core.fail_outbound_delivery(
    p_job_id UUID,p_error TEXT,p_provider_response JSONB
)
RETURNS JSONB
LANGUAGE plpgsql
VOLATILE
AS $function$
DECLARE
    v_job core.integration_jobs%ROWTYPE;
    v_result JSONB;
    v_message_id UUID;
    v_campaign_recipient UUID;
BEGIN
    SELECT * INTO v_job FROM core.integration_jobs WHERE id=p_job_id FOR UPDATE;
    IF NOT FOUND THEN RETURN jsonb_build_object('ok',false,'code','JOB_NOT_FOUND'); END IF;

    v_result := core.fail_integration_job_v1(p_job_id,p_error,p_provider_response);
    v_message_id := nullif(v_job.payload ->> 'internal_message_id','')::uuid;
    v_campaign_recipient := nullif(v_job.payload ->> 'campaign_recipient_id','')::uuid;

    IF v_result ->> 'status' = 'DEAD' THEN
        IF v_message_id IS NOT NULL THEN
            UPDATE core.messages
            SET delivery_status='FAILED', processing_error=left(coalesce(p_error,'UNKNOWN'),4000), updated_at=now()
            WHERE business_id=v_job.business_id AND id=v_message_id;
        END IF;
        IF v_campaign_recipient IS NOT NULL THEN
            UPDATE core.campaign_recipients
            SET status='FAILED', failure_reason=left(coalesce(p_error,'UNKNOWN'),1000), updated_at=now()
            WHERE id=v_campaign_recipient AND business_id=v_job.business_id;
        END IF;
    END IF;

    RETURN v_result;
END;
$function$;

CREATE OR REPLACE FUNCTION core.ingest_whatsapp_delivery_status_v1(
    p_external_message_id TEXT,
    p_status TEXT,
    p_provider_timestamp TIMESTAMPTZ,
    p_payload JSONB DEFAULT '{}'::jsonb
)
RETURNS JSONB
LANGUAGE plpgsql
VOLATILE
AS $function$
DECLARE
    v_message core.messages%ROWTYPE;
    v_status TEXT := upper(coalesce(p_status,''));
    v_allowed TEXT[] := ARRAY['SENT','DELIVERED','READ','FAILED'];
BEGIN
    IF NOT (v_status = ANY(v_allowed)) THEN
        RETURN jsonb_build_object('ok',true,'code','DELIVERY_STATUS_IGNORED','status',v_status);
    END IF;

    SELECT * INTO v_message
    FROM core.messages m
    WHERE m.provider='META' AND m.external_message_id=p_external_message_id
    ORDER BY m.created_at DESC LIMIT 1
    FOR UPDATE;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('ok',true,'code','DELIVERY_MESSAGE_NOT_FOUND','external_message_id',p_external_message_id);
    END IF;

    -- Never downgrade a delivery state. FAILED is terminal only if a later success wasn't already observed.
    IF v_status='READ'
       OR (v_status='DELIVERED' AND v_message.delivery_status NOT IN ('READ'))
       OR (v_status='SENT' AND v_message.delivery_status IN ('QUEUED','NOT_APPLICABLE'))
       OR (v_status='FAILED' AND v_message.delivery_status NOT IN ('DELIVERED','READ'))
    THEN
        UPDATE core.messages
        SET delivery_status=v_status, updated_at=now()
        WHERE business_id=v_message.business_id AND id=v_message.id;
    END IF;

    INSERT INTO core.message_delivery_events(
        business_id,message_id,provider,external_message_id,delivery_status,provider_timestamp,payload
    ) VALUES (
        v_message.business_id,v_message.id,'META',p_external_message_id,v_status,p_provider_timestamp,coalesce(p_payload,'{}'::jsonb)
    );

    UPDATE core.campaign_recipients cr
    SET status=CASE v_status WHEN 'READ' THEN 'READ' WHEN 'DELIVERED' THEN 'DELIVERED' WHEN 'FAILED' THEN 'FAILED' ELSE cr.status END,
        delivered_at=CASE WHEN v_status IN ('DELIVERED','READ') THEN coalesce(cr.delivered_at,now()) ELSE cr.delivered_at END,
        read_at=CASE WHEN v_status='READ' THEN coalesce(cr.read_at,now()) ELSE cr.read_at END,
        updated_at=now()
    WHERE cr.outbound_message_id=v_message.id;

    RETURN jsonb_build_object('ok',true,'code','DELIVERY_STATUS_RECORDED','message_id',v_message.id,'status',v_status);
END;
$function$;

CREATE OR REPLACE FUNCTION core.enqueue_calendar_sync_job_v2(
    p_business_id UUID,p_appointment_id UUID,p_operation TEXT,p_execution_ref TEXT,p_causal_job_id UUID DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
VOLATILE
AS $function$
DECLARE
    v_sync JSONB;
    v_appt JSONB;
    v_operation TEXT := upper(coalesce(p_operation,''));
    v_service_summary TEXT;
    v_customer_name TEXT;
    v_professional_name TEXT;
    v_summary TEXT;
    v_description TEXT;
    v_job_id UUID;
    v_sync_id UUID;
BEGIN
    IF v_operation NOT IN ('CREATE','DELETE') THEN
        RETURN jsonb_build_object('ok',false,'code','INVALID_CALENDAR_OPERATION');
    END IF;

    v_sync := core.prepare_appointment_calendar_sync(p_business_id,p_appointment_id,v_operation);
    IF coalesce((v_sync ->> 'ok')::boolean,false) IS NOT TRUE THEN
        RETURN v_sync || jsonb_build_object('queued',false);
    END IF;

    IF v_sync ->> 'code' = 'CALENDAR_ALREADY_SYNCED' THEN
        RETURN v_sync || jsonb_build_object('queued',false,'already_synced',true);
    END IF;

    v_appt := coalesce(v_sync -> 'appointment','{}'::jsonb);
    v_sync_id := nullif(v_sync ->> 'sync_id','')::uuid;

    SELECT coalesce(string_agg(ai.service_name_snapshot,' + ' ORDER BY ai.display_order),'Atendimento')
    INTO v_service_summary
    FROM core.appointment_items ai
    WHERE ai.business_id=p_business_id AND ai.appointment_id=p_appointment_id;

    SELECT coalesce(c.name,'Cliente') INTO v_customer_name
    FROM core.appointments a
    JOIN core.customers c ON c.business_id=a.business_id AND c.id=a.customer_id
    WHERE a.business_id=p_business_id AND a.id=p_appointment_id;

    SELECT coalesce(p.display_name,p.name,'Profissional') INTO v_professional_name
    FROM core.appointments a
    JOIN core.professionals p ON p.business_id=a.business_id AND p.id=a.professional_id
    WHERE a.business_id=p_business_id AND a.id=p_appointment_id;

    v_summary := left(coalesce(v_service_summary,'Atendimento') || ' - ' || coalesce(v_customer_name,'Cliente') || ' | ' || coalesce(v_professional_name,'Profissional'), 255);
    v_description := concat_ws(E'\n',
        'Cliente: ' || coalesce(v_customer_name,'Cliente'),
        'Serviço: ' || coalesce(v_service_summary,'Atendimento'),
        'Profissional: ' || coalesce(v_professional_name,'Profissional'),
        CASE WHEN nullif(v_appt ->> 'total_price','') IS NOT NULL THEN 'Valor: R$ ' || replace(v_appt ->> 'total_price','.',',') END,
        'ML Appointment: ' || p_appointment_id,
        'Criado automaticamente pela ML Automações.'
    );

    v_job_id := core.enqueue_integration_job_v1(
        p_business_id,'CALENDAR_SYNC',v_operation,
        jsonb_build_object(
            'sync_id',v_sync_id,
            'appointment_id',p_appointment_id,
            'external_calendar_id',v_sync ->> 'external_calendar_id',
            'external_event_id',v_sync ->> 'external_event_id',
            'start_at',v_appt ->> 'start_at',
            'end_at',v_appt ->> 'end_at',
            'summary',v_summary,
            'description',v_description
        ),
        'CAL:' || v_operation || ':' || p_appointment_id || ':' || coalesce(v_sync_id::text,'none'),
        'APPOINTMENT',p_appointment_id,
        CASE WHEN v_operation='DELETE' THEN 50 ELSE 60 END,
        8,now(),p_execution_ref,p_causal_job_id
    );

    RETURN jsonb_build_object('ok',true,'code','CALENDAR_JOB_QUEUED','job_id',v_job_id,'sync',v_sync);
END;
$function$;

CREATE OR REPLACE FUNCTION core.complete_calendar_sync_job(
    p_job_id UUID,p_external_event_id TEXT,p_provider_response JSONB
)
RETURNS JSONB
LANGUAGE plpgsql
VOLATILE
AS $function$
DECLARE
    v_job core.integration_jobs%ROWTYPE;
    v_sync_id UUID;
    v_core JSONB;
    v_job_result JSONB;
BEGIN
    SELECT * INTO v_job FROM core.integration_jobs WHERE id=p_job_id FOR UPDATE;
    IF NOT FOUND THEN RETURN jsonb_build_object('ok',false,'code','JOB_NOT_FOUND'); END IF;
    v_sync_id := nullif(v_job.payload ->> 'sync_id','')::uuid;

    IF v_sync_id IS NOT NULL THEN
        v_core := core.complete_appointment_calendar_sync(
            v_sync_id,
            coalesce(nullif(p_external_event_id,''),v_job.payload ->> 'external_event_id'),
            coalesce(p_provider_response,'{}'::jsonb) || jsonb_build_object('operation',v_job.operation)
        );
        IF coalesce((v_core ->> 'ok')::boolean,false) IS NOT TRUE THEN
            RETURN core.fail_integration_job_v1(p_job_id,'CORE_CALENDAR_COMPLETION_FAILED',jsonb_build_object('core',v_core,'provider',p_provider_response));
        END IF;
    END IF;

    v_job_result := core.complete_integration_job_v1(
        p_job_id,
        coalesce(p_provider_response,'{}'::jsonb) || jsonb_build_object('external_event_id',p_external_event_id,'core',v_core)
    );
    RETURN v_job_result;
END;
$function$;

CREATE OR REPLACE FUNCTION core.fail_calendar_sync_job(
    p_job_id UUID,p_error TEXT,p_provider_response JSONB
)
RETURNS JSONB
LANGUAGE plpgsql
VOLATILE
AS $function$
DECLARE
    v_job core.integration_jobs%ROWTYPE;
    v_sync_id UUID;
    v_job_result JSONB;
BEGIN
    SELECT * INTO v_job FROM core.integration_jobs WHERE id=p_job_id FOR UPDATE;
    IF NOT FOUND THEN RETURN jsonb_build_object('ok',false,'code','JOB_NOT_FOUND'); END IF;
    v_sync_id := nullif(v_job.payload ->> 'sync_id','')::uuid;

    v_job_result := core.fail_integration_job_v1(p_job_id,p_error,p_provider_response);
    IF v_sync_id IS NOT NULL AND v_job_result ->> 'status' = 'DEAD' THEN
        PERFORM core.fail_appointment_calendar_sync(v_sync_id,left(coalesce(p_error,'UNKNOWN'),4000),coalesce(p_provider_response,'{}'::jsonb));
    END IF;
    RETURN v_job_result;
END;
$function$;
