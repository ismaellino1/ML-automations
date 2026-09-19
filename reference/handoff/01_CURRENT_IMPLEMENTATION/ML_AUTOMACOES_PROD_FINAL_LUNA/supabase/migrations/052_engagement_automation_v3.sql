-- 052_engagement_automation_v3.sql
-- Consent, reminders, reactivation and marketing campaigns with suppression/frequency controls.

CREATE TABLE IF NOT EXISTS core.marketing_consent_events (
    id BIGSERIAL PRIMARY KEY,
    business_id UUID NOT NULL,
    customer_id UUID NOT NULL,
    marketing_opt_in BOOLEAN NOT NULL,
    source TEXT NOT NULL,
    actor_ref TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

ALTER TABLE core.campaigns
    ADD COLUMN IF NOT EXISTS template_name TEXT,
    ADD COLUMN IF NOT EXISTS template_language TEXT NOT NULL DEFAULT 'pt_BR',
    ADD COLUMN IF NOT EXISTS quiet_hours JSONB NOT NULL DEFAULT '{"start":"20:00","end":"08:00"}'::jsonb,
    ADD COLUMN IF NOT EXISTS attribution_window_days INTEGER NOT NULL DEFAULT 14,
    ADD COLUMN IF NOT EXISTS completed_at TIMESTAMPTZ;

ALTER TABLE core.campaign_recipients
    ADD COLUMN IF NOT EXISTS outbound_message_id UUID,
    ADD COLUMN IF NOT EXISTS sent_at TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS delivered_at TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS read_at TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS converted_at TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS attributed_appointment_id UUID,
    ADD COLUMN IF NOT EXISTS failure_reason TEXT;

CREATE INDEX IF NOT EXISTS idx_campaign_recipients_customer_history
ON core.campaign_recipients(business_id,customer_id,sent_at DESC)
WHERE status IN ('QUEUED','SENT','DELIVERED','READ','CONVERTED');

CREATE OR REPLACE FUNCTION core.set_marketing_consent_v2(
    p_business_id UUID,p_customer_id UUID,p_opt_in BOOLEAN,p_source TEXT DEFAULT 'CUSTOMER',p_actor_ref TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
VOLATILE
AS $function$
BEGIN
    INSERT INTO core.customer_preferences(business_id,customer_id,marketing_opt_in)
    VALUES(p_business_id,p_customer_id,p_opt_in)
    ON CONFLICT(business_id,customer_id)
    DO UPDATE SET marketing_opt_in=excluded.marketing_opt_in,updated_at=now();

    INSERT INTO core.marketing_consent_events(business_id,customer_id,marketing_opt_in,source,actor_ref)
    VALUES(p_business_id,p_customer_id,p_opt_in,coalesce(nullif(p_source,''),'UNKNOWN'),p_actor_ref);

    IF p_opt_in IS FALSE THEN
        UPDATE core.campaign_recipients
        SET status='SUPPRESSED',suppression_reason='OPTED_OUT',updated_at=now()
        WHERE business_id=p_business_id AND customer_id=p_customer_id AND status IN ('ELIGIBLE','QUEUED');
    END IF;

    RETURN jsonb_build_object('ok',true,'code','MARKETING_PREFERENCE_UPDATED','marketing_opt_in',p_opt_in);
END;
$function$;

CREATE OR REPLACE FUNCTION core.set_marketing_consent_v1(
    p_business_id UUID,p_customer_id UUID,p_opt_in BOOLEAN,p_source TEXT DEFAULT 'CUSTOMER'
)
RETURNS JSONB LANGUAGE sql VOLATILE AS $function$
SELECT core.set_marketing_consent_v2(p_business_id,p_customer_id,p_opt_in,p_source,NULL);
$function$;

CREATE OR REPLACE FUNCTION core.enqueue_due_reminders(p_limit INTEGER,p_execution_ref TEXT)
RETURNS JSONB
LANGUAGE plpgsql
VOLATILE
AS $function$
DECLARE
    r RECORD;
    v_first INTEGER;
    v_second INTEGER;
    v_stage TEXT;
    v_hours INTEGER;
    v_key TEXT;
    v_template_name TEXT;
    v_template_language TEXT;
    v_text TEXT;
    v_result JSONB;
    v_count INTEGER := 0;
    v_template_required INTEGER := 0;
BEGIN
    FOR r IN
        SELECT
            a.id AS appointment_id,a.business_id,a.customer_id,a.start_at,a.end_at,a.total_price,a.currency,
            b.timezone,
            bs.reminder_first_hours_before,bs.reminder_second_hours_before,bs.extra_settings,
            coalesce(cp.reminders_enabled,true) AS customer_reminders,
            coalesce(string_agg(ai.service_name_snapshot,' + ' ORDER BY ai.display_order),'Atendimento') AS service_summary,
            coalesce(p.display_name,p.name,'Profissional') AS professional_name
        FROM core.appointments a
        JOIN core.businesses b ON b.id=a.business_id
        JOIN core.business_settings bs ON bs.business_id=a.business_id AND bs.reminders_enabled=true
        LEFT JOIN core.customer_preferences cp ON cp.business_id=a.business_id AND cp.customer_id=a.customer_id
        LEFT JOIN core.appointment_items ai ON ai.business_id=a.business_id AND ai.appointment_id=a.id
        JOIN core.professionals p ON p.business_id=a.business_id AND p.id=a.professional_id
        WHERE a.status='CONFIRMED'
          AND a.start_at>now()
          AND a.start_at<=now()+interval '48 hours'
        GROUP BY a.id,a.business_id,a.customer_id,a.start_at,a.end_at,a.total_price,a.currency,b.timezone,
                 bs.reminder_first_hours_before,bs.reminder_second_hours_before,bs.extra_settings,cp.reminders_enabled,
                 p.display_name,p.name
        ORDER BY a.start_at
        LIMIT greatest(1,least(coalesce(p_limit,500),2000))
    LOOP
        IF r.customer_reminders IS NOT TRUE THEN CONTINUE; END IF;
        v_first := r.reminder_first_hours_before;
        v_second := r.reminder_second_hours_before;

        FOR v_stage,v_hours IN
            SELECT x.stage,x.hours_before
            FROM (VALUES ('FIRST',v_first),('SECOND',v_second)) AS x(stage,hours_before)
            WHERE x.hours_before IS NOT NULL AND x.hours_before>0
        LOOP
            -- Polling-safe window: reminder becomes eligible at threshold and dedupe prevents repeats.
            IF r.start_at <= now()+make_interval(hours=>v_hours) THEN
                v_key := 'REMINDER:'||r.appointment_id||':'||v_stage||':'||v_hours;
                v_template_name := nullif(r.extra_settings #>> ARRAY['whatsapp_templates','appointment_reminder_'||lower(v_stage),'name'],'');
                v_template_language := coalesce(
                    nullif(r.extra_settings #>> ARRAY['whatsapp_templates','appointment_reminder_'||lower(v_stage),'language'],''),
                    'pt_BR'
                );
                v_text := format(
                    'Lembrete: seu horário de %s com %s é %s às %s.',
                    r.service_summary,
                    r.professional_name,
                    to_char(r.start_at AT TIME ZONE r.timezone,'DD/MM/YYYY'),
                    to_char(r.start_at AT TIME ZONE r.timezone,'HH24:MI')
                );
                v_result := core.queue_outbound_notification_v3(
                    r.business_id,r.customer_id,'APPOINTMENT_REMINDER',
                    jsonb_strip_nulls(jsonb_build_object(
                        'text',v_text,
                        'template_name',v_template_name,
                        'template_language',v_template_language,
                        'metadata',jsonb_build_object('appointment_id',r.appointment_id,'stage',v_stage,'hours_before',v_hours)
                    )),
                    v_key,p_execution_ref,'{}'::jsonb,'INFORMATION'
                );
                IF v_result ->> 'code'='WHATSAPP_TEMPLATE_REQUIRED' THEN
                    v_template_required:=v_template_required+1;
                ELSIF coalesce((v_result->>'ok')::boolean,false) THEN
                    v_count:=v_count+1;
                END IF;
            END IF;
        END LOOP;
    END LOOP;

    RETURN jsonb_build_object('ok',true,'queued',v_count,'template_required',v_template_required);
END;
$function$;

CREATE OR REPLACE FUNCTION core.enqueue_due_reactivation(p_limit INTEGER,p_execution_ref TEXT)
RETURNS JSONB
LANGUAGE plpgsql
VOLATILE
AS $function$
DECLARE
    r RECORD;
    v_result JSONB;
    v_text TEXT;
    v_key TEXT;
    v_template_name TEXT;
    v_template_language TEXT;
    v_count INTEGER := 0;
    v_skipped_template INTEGER := 0;
BEGIN
    FOR r IN
        SELECT
            ep.business_id,ep.customer_id,ep.completed_total,ep.interval_confidence,ep.next_expected_at,
            ep.last_reactivation_at,ep.reactivation_suppressed_until,
            bs.reactivation_cooldown_days,bs.extra_settings,b.timezone
        FROM core.customer_engagement_profiles ep
        JOIN core.business_settings bs ON bs.business_id=ep.business_id AND bs.reactivation_enabled=true
        JOIN core.businesses b ON b.id=ep.business_id
        JOIN core.customer_preferences cp ON cp.business_id=ep.business_id AND cp.customer_id=ep.customer_id
        WHERE ep.reactivation_eligible=true
          AND cp.reactivation_opt_in=true
          AND ep.completed_total>=bs.reactivation_min_completed
          AND ep.interval_confidence>=bs.reactivation_min_confidence
          AND ep.next_expected_at IS NOT NULL
          AND ep.next_expected_at<=now()
          AND (ep.reactivation_suppressed_until IS NULL OR ep.reactivation_suppressed_until<=now())
          AND (ep.last_reactivation_at IS NULL OR ep.last_reactivation_at<=now()-make_interval(days=>bs.reactivation_cooldown_days))
        ORDER BY ep.next_expected_at
        LIMIT greatest(1,least(coalesce(p_limit,250),1000))
        FOR UPDATE OF ep SKIP LOCKED
    LOOP
        v_key := 'REACTIVATION:'||r.customer_id||':'||to_char(r.next_expected_at AT TIME ZONE r.timezone,'YYYY-MM-DD');
        v_template_name := nullif(r.extra_settings #>> '{whatsapp_templates,reactivation,name}','');
        v_template_language := coalesce(nullif(r.extra_settings #>> '{whatsapp_templates,reactivation,language}',''),'pt_BR');
        v_text := 'Oi! Faz um tempinho desde seu último atendimento. Se quiser, posso procurar um horário pra você.';
        v_result := core.queue_outbound_notification_v3(
            r.business_id,r.customer_id,'REACTIVATION',
            jsonb_strip_nulls(jsonb_build_object(
                'text',v_text,'template_name',v_template_name,'template_language',v_template_language,
                'metadata',jsonb_build_object('next_expected_at',r.next_expected_at)
            )),v_key,p_execution_ref,'{}'::jsonb,'INFORMATION'
        );
        IF v_result ->> 'code'='WHATSAPP_TEMPLATE_REQUIRED' THEN
            v_skipped_template:=v_skipped_template+1;
        ELSIF coalesce((v_result->>'ok')::boolean,false) THEN
            UPDATE core.customer_engagement_profiles
            SET last_reactivation_at=now(),
                reactivation_suppressed_until=now()+make_interval(days=>r.reactivation_cooldown_days),
                updated_at=now()
            WHERE business_id=r.business_id AND customer_id=r.customer_id;
            v_count:=v_count+1;
        END IF;
    END LOOP;

    RETURN jsonb_build_object('ok',true,'queued',v_count,'template_required',v_skipped_template);
END;
$function$;

CREATE OR REPLACE FUNCTION core.enqueue_due_campaign_jobs(p_limit INTEGER,p_execution_ref TEXT)
RETURNS JSONB
LANGUAGE plpgsql
VOLATILE
AS $function$
DECLARE r RECORD; c INTEGER:=0;
BEGIN
    FOR r IN
        SELECT * FROM core.campaigns
        WHERE status='SCHEDULED'
          AND coalesce(scheduled_at,starts_at,now())<=now()
          AND (starts_at IS NULL OR starts_at<=now())
          AND (ends_at IS NULL OR ends_at>now())
        ORDER BY coalesce(scheduled_at,starts_at,created_at)
        LIMIT greatest(1,least(coalesce(p_limit,100),1000))
        FOR UPDATE SKIP LOCKED
    LOOP
        UPDATE core.campaigns SET status='RUNNING',updated_at=now() WHERE id=r.id;
        PERFORM core.enqueue_integration_job_v1(
            r.business_id,'CAMPAIGN_MATERIALIZE','MATERIALIZE',jsonb_build_object('campaign_id',r.id),
            'CAMPAIGN_MATERIALIZE:'||r.id,'CAMPAIGN',r.id,80,5,now(),p_execution_ref,NULL
        );
        c:=c+1;
    END LOOP;
    RETURN jsonb_build_object('ok',true,'started',c);
END;
$function$;

CREATE OR REPLACE FUNCTION core.materialize_due_campaign_recipients(p_limit INTEGER,p_execution_ref TEXT)
RETURNS JSONB
LANGUAGE plpgsql
VOLATILE
AS $function$
DECLARE
    j RECORD;
    camp core.campaigns%ROWTYPE;
    rules JSONB;
    v_max INTEGER;
    v_count INTEGER:=0;
BEGIN
    FOR j IN
        SELECT * FROM core.integration_jobs
        WHERE job_type='CAMPAIGN_MATERIALIZE'
          AND status IN ('PENDING','RETRY') AND next_attempt_at<=now()
        ORDER BY created_at
        LIMIT greatest(1,least(coalesce(p_limit,100),500))
        FOR UPDATE SKIP LOCKED
    LOOP
        SELECT * INTO camp FROM core.campaigns WHERE id=(j.payload->>'campaign_id')::uuid FOR UPDATE;
        IF NOT FOUND OR camp.status<>'RUNNING' THEN
            PERFORM core.complete_integration_job_v1(j.id,jsonb_build_object('skipped',true));
            CONTINUE;
        END IF;
        rules:=coalesce(camp.audience_rules,'{}'::jsonb);
        v_max:=greatest(1,least(coalesce(nullif(rules->>'max_recipients','')::integer,100000),100000));

        INSERT INTO core.campaign_recipients(campaign_id,business_id,customer_id,status,suppression_reason)
        SELECT
            camp.id,camp.business_id,
            c.id,
            CASE
                WHEN coalesce(cp.marketing_opt_in,false) IS NOT TRUE THEN 'SUPPRESSED'
                WHEN EXISTS(
                    SELECT 1 FROM core.campaign_recipients prev
                    WHERE prev.business_id=camp.business_id AND prev.customer_id=c.id
                      AND prev.status IN ('QUEUED','SENT','DELIVERED','READ','CONVERTED')
                      AND prev.sent_at IS NOT NULL
                      AND prev.sent_at>now()-make_interval(days=>greatest(0,camp.frequency_cap_days))
                ) THEN 'SUPPRESSED'
                ELSE 'ELIGIBLE'
            END,
            CASE
                WHEN coalesce(cp.marketing_opt_in,false) IS NOT TRUE THEN 'MARKETING_OPT_OUT'
                WHEN EXISTS(
                    SELECT 1 FROM core.campaign_recipients prev
                    WHERE prev.business_id=camp.business_id AND prev.customer_id=c.id
                      AND prev.status IN ('QUEUED','SENT','DELIVERED','READ','CONVERTED')
                      AND prev.sent_at IS NOT NULL
                      AND prev.sent_at>now()-make_interval(days=>greatest(0,camp.frequency_cap_days))
                ) THEN 'FREQUENCY_CAP'
                ELSE NULL
            END
        FROM core.customers c
        LEFT JOIN core.customer_preferences cp ON cp.business_id=c.business_id AND cp.customer_id=c.id
        LEFT JOIN core.customer_engagement_profiles ep ON ep.business_id=c.business_id AND ep.customer_id=c.id
        WHERE c.business_id=camp.business_id
          AND (jsonb_typeof(rules->'customer_ids') IS DISTINCT FROM 'array'
               OR jsonb_array_length(rules->'customer_ids')=0
               OR c.id::text IN (SELECT jsonb_array_elements_text(rules->'customer_ids')))
          AND (nullif(rules->>'min_completed','') IS NULL OR coalesce(ep.completed_total,0)>= (rules->>'min_completed')::integer)
          AND (nullif(rules->>'recurring_only','') IS NULL OR (rules->>'recurring_only')::boolean IS FALSE OR coalesce(ep.is_recurring,false)=true)
          AND (nullif(rules->>'inactive_days_min','') IS NULL
               OR ep.last_completed_at IS NULL
               OR ep.last_completed_at<=now()-make_interval(days=>(rules->>'inactive_days_min')::integer))
          AND (nullif(rules->>'inactive_days_max','') IS NULL
               OR ep.last_completed_at IS NULL
               OR ep.last_completed_at>=now()-make_interval(days=>(rules->>'inactive_days_max')::integer))
        ORDER BY coalesce(ep.last_completed_at,'epoch'::timestamptz)
        LIMIT v_max
        ON CONFLICT(campaign_id,customer_id) DO NOTHING;

        PERFORM core.complete_integration_job_v1(j.id,jsonb_build_object('materialized',true));
        v_count:=v_count+1;
    END LOOP;
    RETURN jsonb_build_object('ok',true,'materialized_jobs',v_count);
END;
$function$;

CREATE OR REPLACE FUNCTION core.enqueue_campaign_deliveries(p_limit INTEGER,p_execution_ref TEXT)
RETURNS JSONB
LANGUAGE plpgsql
VOLATILE
AS $function$
DECLARE
    r RECORD;
    camp core.campaigns%ROWTYPE;
    v_result JSONB;
    v_count INTEGER:=0;
    v_suppressed INTEGER:=0;
BEGIN
    FOR r IN
        SELECT cr.*
        FROM core.campaign_recipients cr
        JOIN core.campaigns c ON c.id=cr.campaign_id
        WHERE cr.status='ELIGIBLE' AND c.status='RUNNING'
          AND (c.ends_at IS NULL OR c.ends_at>now())
        ORDER BY cr.created_at
        LIMIT greatest(1,least(coalesce(p_limit,500),2000))
        FOR UPDATE OF cr SKIP LOCKED
    LOOP
        SELECT * INTO camp FROM core.campaigns WHERE id=r.campaign_id;
        -- Scheduled marketing is template-first. If no approved template is configured, suppress rather than violate channel policy.
        IF nullif(camp.template_name,'') IS NULL THEN
            UPDATE core.campaign_recipients SET status='SUPPRESSED',suppression_reason='APPROVED_TEMPLATE_REQUIRED',updated_at=now() WHERE id=r.id;
            v_suppressed:=v_suppressed+1;
            CONTINUE;
        END IF;

        v_result:=core.queue_outbound_notification_v3(
            r.business_id,r.customer_id,'CAMPAIGN',
            jsonb_build_object(
                'text',coalesce(camp.content->>'text',camp.name),
                'template_name',camp.template_name,
                'template_language',camp.template_language,
                'template_components',coalesce(camp.content->'template_components','[]'::jsonb),
                'campaign_recipient_id',r.id,
                'metadata',jsonb_build_object('campaign_id',camp.id,'campaign_recipient_id',r.id)
            ),
            'CAMPAIGN:'||camp.id||':'||r.customer_id,
            p_execution_ref,'{}'::jsonb,'INFORMATION'
        );

        IF coalesce((v_result->>'ok')::boolean,false) AND coalesce((v_result->>'should_send')::boolean,false) THEN
            UPDATE core.campaign_recipients
            SET status='QUEUED',outbound_message_id=nullif(v_result->>'internal_message_id','')::uuid,updated_at=now()
            WHERE id=r.id;
            v_count:=v_count+1;
        ELSE
            UPDATE core.campaign_recipients
            SET status='SUPPRESSED',suppression_reason=coalesce(v_result->>'code','DELIVERY_NOT_QUEUED'),updated_at=now()
            WHERE id=r.id;
            v_suppressed:=v_suppressed+1;
        END IF;
    END LOOP;

    IF NOT EXISTS(
        SELECT 1 FROM core.campaign_recipients cr JOIN core.campaigns c ON c.id=cr.campaign_id
        WHERE c.status='RUNNING' AND cr.status IN ('ELIGIBLE','QUEUED')
    ) THEN
        UPDATE core.campaigns c
        SET status='COMPLETED',completed_at=coalesce(completed_at,now()),updated_at=now()
        WHERE status='RUNNING'
          AND NOT EXISTS(SELECT 1 FROM core.campaign_recipients cr WHERE cr.campaign_id=c.id AND cr.status IN ('ELIGIBLE','QUEUED'));
    END IF;

    RETURN jsonb_build_object('ok',true,'queued',v_count,'suppressed',v_suppressed);
END;
$function$;

CREATE TABLE IF NOT EXISTS core.campaign_conversions (
    id BIGSERIAL PRIMARY KEY,
    campaign_id UUID NOT NULL REFERENCES core.campaigns(id) ON DELETE CASCADE,
    campaign_recipient_id UUID NOT NULL REFERENCES core.campaign_recipients(id) ON DELETE CASCADE,
    business_id UUID NOT NULL,
    customer_id UUID NOT NULL,
    appointment_id UUID NOT NULL,
    conversion_type TEXT NOT NULL DEFAULT 'APPOINTMENT_CONFIRMED',
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE(campaign_recipient_id,appointment_id,conversion_type)
);

CREATE OR REPLACE FUNCTION core.attribute_campaign_conversion_v1(
    p_business_id UUID,p_customer_id UUID,p_appointment_id UUID,p_conversion_type TEXT DEFAULT 'APPOINTMENT_CONFIRMED'
)
RETURNS JSONB
LANGUAGE plpgsql
VOLATILE
AS $function$
DECLARE r RECORD; v_id BIGINT;
BEGIN
    SELECT cr.*,c.attribution_window_days
    INTO r
    FROM core.campaign_recipients cr
    JOIN core.campaigns c ON c.id=cr.campaign_id
    WHERE cr.business_id=p_business_id AND cr.customer_id=p_customer_id
      AND cr.sent_at IS NOT NULL
      AND cr.sent_at>=now()-make_interval(days=>greatest(1,c.attribution_window_days))
      AND cr.status IN ('SENT','DELIVERED','READ','CONVERTED')
    ORDER BY cr.sent_at DESC LIMIT 1;
    IF NOT FOUND THEN RETURN jsonb_build_object('ok',true,'code','NO_ATTRIBUTABLE_CAMPAIGN'); END IF;

    INSERT INTO core.campaign_conversions(campaign_id,campaign_recipient_id,business_id,customer_id,appointment_id,conversion_type)
    VALUES(r.campaign_id,r.id,p_business_id,p_customer_id,p_appointment_id,p_conversion_type)
    ON CONFLICT(campaign_recipient_id,appointment_id,conversion_type) DO NOTHING
    RETURNING id INTO v_id;

    UPDATE core.campaign_recipients SET status='CONVERTED',converted_at=coalesce(converted_at,now()),
      attributed_appointment_id=coalesce(attributed_appointment_id,p_appointment_id),updated_at=now()
    WHERE id=r.id;
    RETURN jsonb_build_object('ok',true,'code','CAMPAIGN_CONVERSION_ATTRIBUTED','conversion_id',v_id,'campaign_id',r.campaign_id);
END;
$function$;

CREATE OR REPLACE VIEW core.campaign_metrics_v1 AS
SELECT
    c.business_id,c.id AS campaign_id,c.name,c.status,
    count(cr.id) AS recipients,
    count(*) FILTER (WHERE cr.status='SUPPRESSED') AS suppressed,
    count(*) FILTER (WHERE cr.sent_at IS NOT NULL) AS sent,
    count(*) FILTER (WHERE cr.delivered_at IS NOT NULL) AS delivered,
    count(*) FILTER (WHERE cr.read_at IS NOT NULL) AS read,
    count(*) FILTER (WHERE cr.converted_at IS NOT NULL) AS converted,
    CASE WHEN count(*) FILTER (WHERE cr.sent_at IS NOT NULL)>0
         THEN round(100.0*count(*) FILTER(WHERE cr.converted_at IS NOT NULL)/count(*) FILTER(WHERE cr.sent_at IS NOT NULL),2)
         ELSE 0 END AS conversion_rate_pct
FROM core.campaigns c
LEFT JOIN core.campaign_recipients cr ON cr.campaign_id=c.id
GROUP BY c.business_id,c.id,c.name,c.status;
