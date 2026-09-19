-- 055_control_plane_final.sql
-- Complete audited Control Plane for ML Admin / ML Manager / ML Employee.
--
-- P0.7 DECISION (2026-09-19): this is now the single canonical control-plane
-- entry point. Before this fix, supabase/functions/control-api/index.ts and
-- n8n/08_ml_control_plane.json both called execute_control_plane_action_v2
-- (047) instead - which only ever implemented 3 actions
-- (SET_MARKETING_CONSENT, UPSERT_PRODUCT, CREATE_CAMPAIGN) - making this
-- complete, ~18-action, per-action-RBAC implementation dead code. Audited
-- before switching (see docs/AUDIT/PHASE_A.md D.4 and
-- supabase/tests/p0/007_p0_7_control_plane.sql):
--   - RBAC: authorize_action_v2's per-action allowlists here are a strict
--     superset of what authorize_action_v1 (047) permitted, and match this
--     function's own implemented action set 1:1 (047's allowlist described
--     actions - CREATE_APPOINTMENT, CANCEL_APPOINTMENT, etc. - that 047's
--     own dispatcher never actually implemented).
--   - Payload/response shape: identical 6 named parameters
--     (p_actor_user_id, p_business_id, p_action, p_arguments,
--     p_idempotency_key, p_execution_ref) as 047, so no caller-side
--     reshaping was needed.
--   - Frontend compatibility: apps/ml-console/src/lib/supabase.ts's
--     control() helper already sends exactly this shape.
--   - core.execute_control_plane_action_v2 (047) is NOT retired - this
--     function delegates 2 of its actions (UPSERT_PRODUCT, CREATE_CAMPAIGN)
--     to it as an internal helper. It must no longer be treated as an
--     independent entry point.
--   - Known limitation carried over from both versions, not introduced by
--     this decision: p_idempotency_key is required but not itself
--     deduplicated at this dispatcher level (no idempotency-key replay
--     cache) - safety today relies on the underlying operations (upserts,
--     core.cancel_appointment's own idempotency) being naturally safe to
--     repeat. See KNOWN_LIMITATIONS.md.

ALTER TABLE core.business_memberships
  ADD COLUMN IF NOT EXISTS professional_id UUID;

CREATE INDEX IF NOT EXISTS idx_business_memberships_professional
ON core.business_memberships(business_id,professional_id) WHERE professional_id IS NOT NULL AND active=true;

CREATE OR REPLACE FUNCTION private.user_role_for_business_v2(p_user UUID,p_business UUID)
RETURNS JSONB
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path=''
AS $function$
SELECT CASE
 WHEN EXISTS(SELECT 1 FROM core.platform_admins a WHERE a.user_id=p_user AND a.active)
   THEN jsonb_build_object('role','PLATFORM_ADMIN','professional_id',NULL)
 ELSE coalesce((SELECT jsonb_build_object('role',m.role,'professional_id',m.professional_id)
                FROM core.business_memberships m
                WHERE m.user_id=p_user AND m.business_id=p_business AND m.active LIMIT 1),'{}'::jsonb)
 END;
$function$;
REVOKE ALL ON FUNCTION private.user_role_for_business_v2(UUID,UUID) FROM PUBLIC;

CREATE OR REPLACE FUNCTION core.authorize_action_v2(p_user UUID,p_business UUID,p_action TEXT)
RETURNS BOOLEAN
LANGUAGE plpgsql STABLE
AS $function$
DECLARE r TEXT; a TEXT:=upper(coalesce(p_action,''));
BEGIN
 r:=private.user_role_for_business_v2(p_user,p_business)->>'role';
 IF r='PLATFORM_ADMIN' THEN RETURN true; END IF;
 IF r='OWNER' THEN RETURN a NOT IN ('CREATE_BUSINESS','DELETE_PLATFORM_ADMIN'); END IF;
 IF r='MANAGER' THEN RETURN a = ANY(ARRAY[
   'GET_DASHBOARD','LIST_APPOINTMENTS','LIST_CUSTOMERS','LIST_SERVICES','LIST_PROFESSIONALS','LIST_PRODUCTS',
   'LIST_CAMPAIGNS','LIST_KNOWLEDGE','LIST_AUTOMATION_POLICIES','LIST_INCIDENTS','GET_SETTINGS','LIST_MEMBERS',
   'CANCEL_APPOINTMENT','UPSERT_SERVICE','UPSERT_PROFESSIONAL','SET_PROFESSIONAL_SERVICE','UPSERT_PRODUCT',
   'CREATE_CAMPAIGN','UPDATE_CAMPAIGN_STATUS','UPSERT_KNOWLEDGE','UPDATE_AUTOMATION_POLICY','UPDATE_SETTINGS',
   'SET_MARKETING_CONSENT','SET_CONVERSATION_MODE','ACK_INCIDENT','RESOLVE_INCIDENT','UPSERT_MEMBER'
 ]); END IF;
 IF r='RECEPTIONIST' THEN RETURN a = ANY(ARRAY[
   'GET_DASHBOARD','LIST_APPOINTMENTS','LIST_CUSTOMERS','LIST_SERVICES','LIST_PROFESSIONALS','LIST_PRODUCTS',
   'GET_SETTINGS','CANCEL_APPOINTMENT','SET_MARKETING_CONSENT','SET_CONVERSATION_MODE'
 ]); END IF;
 IF r='EMPLOYEE' THEN RETURN a = ANY(ARRAY[
   'GET_DASHBOARD','LIST_MY_APPOINTMENTS','LIST_SERVICES','LIST_PRODUCTS','GET_SETTINGS'
 ]); END IF;
 IF r='VIEWER' THEN RETURN a = ANY(ARRAY[
   'GET_DASHBOARD','LIST_APPOINTMENTS','LIST_CUSTOMERS','LIST_SERVICES','LIST_PROFESSIONALS','LIST_PRODUCTS',
   'LIST_CAMPAIGNS','LIST_KNOWLEDGE','LIST_AUTOMATION_POLICIES','LIST_INCIDENTS','GET_SETTINGS'
 ]); END IF;
 RETURN false;
END;
$function$;

CREATE OR REPLACE FUNCTION core.get_dashboard_v1(p_business_id UUID,p_user_id UUID)
RETURNS JSONB LANGUAGE plpgsql STABLE AS $function$
DECLARE r JSONB; role_info JSONB; prof UUID;
BEGIN
 role_info:=private.user_role_for_business_v2(p_user_id,p_business_id); prof:=nullif(role_info->>'professional_id','')::uuid;
 IF coalesce(role_info->>'role','')='' THEN RETURN jsonb_build_object('ok',false,'code','FORBIDDEN'); END IF;
 SELECT jsonb_build_object(
  'ok',true,'role',role_info->>'role',
  'today',jsonb_build_object(
    'appointments',(SELECT count(*) FROM core.appointments a JOIN core.businesses b ON b.id=a.business_id
      WHERE a.business_id=p_business_id AND a.status IN('CONFIRMED','CHECKED_IN')
        AND (a.start_at AT TIME ZONE b.timezone)::date=(now() AT TIME ZONE b.timezone)::date
        AND (prof IS NULL OR a.professional_id=prof)),
    'completed',(SELECT count(*) FROM core.appointments a JOIN core.businesses b ON b.id=a.business_id
      WHERE a.business_id=p_business_id AND a.status='COMPLETED'
        AND (a.completed_at AT TIME ZONE b.timezone)::date=(now() AT TIME ZONE b.timezone)::date
        AND (prof IS NULL OR a.professional_id=prof))
  ),
  'queues',jsonb_build_object(
    'pending',(SELECT count(*) FROM core.integration_jobs WHERE business_id=p_business_id AND status IN('PENDING','RETRY')),
    'dead',(SELECT count(*) FROM core.integration_jobs WHERE business_id=p_business_id AND status='DEAD')
  ),
  'incidents_open',(SELECT count(*) FROM core.automation_incidents WHERE business_id=p_business_id AND status='OPEN'),
  'customers',(SELECT count(*) FROM core.customers WHERE business_id=p_business_id AND status='ACTIVE'),
  'upcoming',(SELECT coalesce(jsonb_agg(x ORDER BY x.start_at),'[]'::jsonb) FROM (
     SELECT a.id appointment_id,a.start_at,a.end_at,a.status,c.name customer_name,coalesce(p.display_name,p.name) professional_name,
       coalesce((SELECT string_agg(ai.service_name_snapshot,' + ' ORDER BY ai.display_order) FROM core.appointment_items ai WHERE ai.business_id=a.business_id AND ai.appointment_id=a.id),'Atendimento') service_summary
     FROM core.appointments a JOIN core.customers c ON c.business_id=a.business_id AND c.id=a.customer_id
     JOIN core.professionals p ON p.business_id=a.business_id AND p.id=a.professional_id
     WHERE a.business_id=p_business_id AND a.start_at>=now() AND a.status IN('CONFIRMED','CHECKED_IN')
       AND (prof IS NULL OR a.professional_id=prof)
     ORDER BY a.start_at LIMIT 12
  ) x)
 ) INTO r;
 RETURN r;
END;
$function$;

CREATE OR REPLACE FUNCTION core.control_plane_read_v1(
 p_actor_user_id UUID,p_business_id UUID,p_action TEXT,p_arguments JSONB DEFAULT '{}'::jsonb
) RETURNS JSONB LANGUAGE plpgsql STABLE AS $function$
DECLARE a TEXT:=upper(coalesce(p_action,'')); role_info JSONB; prof UUID; lim INTEGER:=greatest(1,least(coalesce(nullif(p_arguments->>'limit','')::int,100),500)); off INTEGER:=greatest(0,coalesce(nullif(p_arguments->>'offset','')::int,0)); out JSONB;
BEGIN
 IF NOT core.authorize_action_v2(p_actor_user_id,p_business_id,a) THEN RETURN jsonb_build_object('ok',false,'code','FORBIDDEN'); END IF;
 role_info:=private.user_role_for_business_v2(p_actor_user_id,p_business_id); prof:=nullif(role_info->>'professional_id','')::uuid;
 IF a='GET_DASHBOARD' THEN RETURN core.get_dashboard_v1(p_business_id,p_actor_user_id); END IF;
 IF a IN('LIST_APPOINTMENTS','LIST_MY_APPOINTMENTS') THEN
   SELECT jsonb_build_object('ok',true,'items',coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb)) INTO out FROM (
    SELECT ap.id,ap.status,ap.start_at,ap.end_at,ap.total_price,ap.currency,ap.customer_id,c.name customer_name,ap.professional_id,
      coalesce(pr.display_name,pr.name) professional_name,
      coalesce((SELECT string_agg(ai.service_name_snapshot,' + ' ORDER BY ai.display_order) FROM core.appointment_items ai WHERE ai.business_id=ap.business_id AND ai.appointment_id=ap.id),'Atendimento') service_summary
    FROM core.appointments ap JOIN core.customers c ON c.business_id=ap.business_id AND c.id=ap.customer_id
    JOIN core.professionals pr ON pr.business_id=ap.business_id AND pr.id=ap.professional_id
    WHERE ap.business_id=p_business_id
      AND (nullif(p_arguments->>'status','') IS NULL OR ap.status=upper(p_arguments->>'status'))
      AND (nullif(p_arguments->>'from','') IS NULL OR ap.start_at>=(p_arguments->>'from')::timestamptz)
      AND (nullif(p_arguments->>'until','') IS NULL OR ap.start_at<=(p_arguments->>'until')::timestamptz)
      AND (a<>'LIST_MY_APPOINTMENTS' OR (prof IS NOT NULL AND ap.professional_id=prof))
    ORDER BY ap.start_at DESC LIMIT lim OFFSET off
   ) x; RETURN out;
 END IF;
 IF a='LIST_CUSTOMERS' THEN
  SELECT jsonb_build_object('ok',true,'items',coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb)) INTO out FROM (
   SELECT c.id,c.name,c.status,c.notes,c.created_at,cp.reminders_enabled,cp.reactivation_opt_in,cp.marketing_opt_in,
          ep.completed_total,ep.cancelled_total,ep.no_show_total,ep.last_completed_at,ep.next_expected_at,ep.is_recurring
   FROM core.customers c LEFT JOIN core.customer_preferences cp ON cp.business_id=c.business_id AND cp.customer_id=c.id
   LEFT JOIN core.customer_engagement_profiles ep ON ep.business_id=c.business_id AND ep.customer_id=c.id
   WHERE c.business_id=p_business_id AND (nullif(p_arguments->>'q','') IS NULL OR c.name ILIKE '%'||(p_arguments->>'q')||'%')
   ORDER BY c.updated_at DESC LIMIT lim OFFSET off
  ) x; RETURN out;
 END IF;
 IF a='LIST_SERVICES' THEN SELECT jsonb_build_object('ok',true,'items',coalesce(jsonb_agg(to_jsonb(s) ORDER BY s.display_order,s.name),'[]'::jsonb)) INTO out FROM core.services s WHERE s.business_id=p_business_id; RETURN out; END IF;
 IF a='LIST_PROFESSIONALS' THEN SELECT jsonb_build_object('ok',true,'items',coalesce(jsonb_agg(to_jsonb(p) ORDER BY p.display_order,p.name),'[]'::jsonb)) INTO out FROM core.professionals p WHERE p.business_id=p_business_id; RETURN out; END IF;
 IF a='LIST_PRODUCTS' THEN SELECT jsonb_build_object('ok',true,'items',coalesce(jsonb_agg(to_jsonb(p) ORDER BY p.name),'[]'::jsonb)) INTO out FROM core.products p WHERE p.business_id=p_business_id; RETURN out; END IF;
 IF a='LIST_CAMPAIGNS' THEN SELECT jsonb_build_object('ok',true,'items',coalesce(jsonb_agg(to_jsonb(c) ORDER BY c.created_at DESC),'[]'::jsonb)) INTO out FROM core.campaigns c WHERE c.business_id=p_business_id; RETURN out; END IF;
 IF a='LIST_KNOWLEDGE' THEN SELECT jsonb_build_object('ok',true,'items',coalesce(jsonb_agg(jsonb_build_object('id',k.id,'external_key',k.external_key,'title',k.title,'content',k.content,'metadata',k.metadata,'active',k.active,'updated_at',k.updated_at) ORDER BY k.updated_at DESC),'[]'::jsonb)) INTO out FROM core.knowledge_documents k WHERE k.business_id=p_business_id; RETURN out; END IF;
 IF a='LIST_AUTOMATION_POLICIES' THEN SELECT jsonb_build_object('ok',true,'items',coalesce(jsonb_agg(to_jsonb(p) ORDER BY p.policy_type),'[]'::jsonb)) INTO out FROM core.automation_policies p WHERE p.business_id=p_business_id; RETURN out; END IF;
 IF a='LIST_INCIDENTS' THEN SELECT jsonb_build_object('ok',true,'items',coalesce(jsonb_agg(to_jsonb(i) ORDER BY i.created_at DESC),'[]'::jsonb)) INTO out FROM (SELECT * FROM core.automation_incidents WHERE business_id=p_business_id AND (nullif(p_arguments->>'status','') IS NULL OR status=upper(p_arguments->>'status')) ORDER BY created_at DESC LIMIT lim OFFSET off) i; RETURN out; END IF;
 IF a='LIST_MEMBERS' THEN SELECT jsonb_build_object('ok',true,'items',coalesce(jsonb_agg(to_jsonb(m) ORDER BY m.created_at),'[]'::jsonb)) INTO out FROM core.business_memberships m WHERE m.business_id=p_business_id; RETURN out; END IF;
 IF a='GET_SETTINGS' THEN
   SELECT jsonb_build_object('ok',true,'business',to_jsonb(b),'settings',to_jsonb(bs),'brand',to_jsonb(bp),'ai',to_jsonb(ai)) INTO out
   FROM core.businesses b LEFT JOIN core.business_settings bs ON bs.business_id=b.id
   LEFT JOIN core.business_brand_profiles bp ON bp.business_id=b.id LEFT JOIN core.business_ai_settings ai ON ai.business_id=b.id
   WHERE b.id=p_business_id; RETURN coalesce(out,jsonb_build_object('ok',false,'code','BUSINESS_NOT_FOUND'));
 END IF;
 RETURN jsonb_build_object('ok',false,'code','READ_ACTION_NOT_SUPPORTED','action',a);
EXCEPTION WHEN invalid_text_representation OR invalid_datetime_format THEN RETURN jsonb_build_object('ok',false,'code','INVALID_FILTER_ARGUMENT');
END;
$function$;

CREATE OR REPLACE FUNCTION core.execute_control_plane_action_final(
 p_actor_user_id UUID,p_business_id UUID,p_action TEXT,p_arguments JSONB,p_idempotency_key TEXT,p_execution_ref TEXT
) RETURNS JSONB LANGUAGE plpgsql VOLATILE AS $function$
DECLARE a TEXT:=upper(coalesce(p_action,'')); r JSONB; role_info JSONB; appt UUID; pro UUID; sid UUID; cid UUID; biz UUID:=p_business_id;
BEGIN
 IF nullif(btrim(p_idempotency_key),'') IS NULL THEN RETURN jsonb_build_object('ok',false,'code','IDEMPOTENCY_KEY_REQUIRED'); END IF;
 IF a LIKE 'GET_%' OR a LIKE 'LIST_%' THEN RETURN core.control_plane_read_v1(p_actor_user_id,p_business_id,a,p_arguments); END IF;

 IF a='CREATE_BUSINESS' THEN
   IF NOT EXISTS(SELECT 1 FROM core.platform_admins WHERE user_id=p_actor_user_id AND active) THEN RETURN jsonb_build_object('ok',false,'code','FORBIDDEN'); END IF;
   INSERT INTO core.businesses(business_code,name,timezone,locale,status,plan_code)
   VALUES(p_arguments->>'business_code',p_arguments->>'name',coalesce(p_arguments->>'timezone','America/Sao_Paulo'),coalesce(p_arguments->>'locale','pt-BR'),'ACTIVE',coalesce(p_arguments->>'plan_code','PRO'))
   RETURNING id INTO biz;
   INSERT INTO core.business_settings(business_id) VALUES(biz) ON CONFLICT(business_id) DO NOTHING;
   INSERT INTO core.business_ai_settings(business_id) VALUES(biz) ON CONFLICT(business_id) DO NOTHING;
   INSERT INTO core.business_brand_profiles(business_id) VALUES(biz) ON CONFLICT(business_id) DO NOTHING;
   IF nullif(p_arguments->>'owner_user_id','') IS NOT NULL THEN
     INSERT INTO core.business_memberships(business_id,user_id,role,active) VALUES(biz,(p_arguments->>'owner_user_id')::uuid,'OWNER',true)
     ON CONFLICT(business_id,user_id) DO UPDATE SET role='OWNER',active=true,updated_at=now();
   END IF;
   r:=jsonb_build_object('ok',true,'code','BUSINESS_CREATED','business_id',biz);
 ELSE
   IF NOT core.authorize_action_v2(p_actor_user_id,p_business_id,a) THEN RETURN jsonb_build_object('ok',false,'code','FORBIDDEN'); END IF;

   IF a='CANCEL_APPOINTMENT' THEN
     appt:=(p_arguments->>'appointment_id')::uuid;
     role_info:=private.user_role_for_business_v2(p_actor_user_id,p_business_id); pro:=nullif(role_info->>'professional_id','')::uuid;
     r:=core.cancel_appointment(p_business_id,appt,
        CASE WHEN role_info->>'role'='EMPLOYEE' THEN 'PROFESSIONAL' ELSE 'BUSINESS' END,
        NULL,pro,p_actor_user_id::text,p_arguments->>'public_reason',p_arguments->>'internal_reason','ML_CONTROL','ML');
     IF coalesce((r->>'ok')::boolean,false) THEN
       PERFORM core.enqueue_calendar_sync_job_v2(p_business_id,appt,'DELETE',p_execution_ref,NULL);
       PERFORM core.enqueue_prepared_cancellation_outbound_v1(p_business_id,appt,p_execution_ref);
     END IF;

   ELSIF a='UPSERT_SERVICE' THEN
     sid:=coalesce(nullif(p_arguments->>'id','')::uuid,gen_random_uuid());
     INSERT INTO core.services(id,business_id,service_code,name,description,price,currency,duration_minutes,buffer_before_minutes,buffer_after_minutes,display_order,active,online_booking_enabled)
     VALUES(sid,p_business_id,p_arguments->>'service_code',p_arguments->>'name',p_arguments->>'description',coalesce((p_arguments->>'price')::numeric,0),coalesce(p_arguments->>'currency','BRL'),
       coalesce((p_arguments->>'duration_minutes')::int,30),coalesce((p_arguments->>'buffer_before_minutes')::int,0),coalesce((p_arguments->>'buffer_after_minutes')::int,0),coalesce((p_arguments->>'display_order')::int,0),
       coalesce((p_arguments->>'active')::boolean,true),coalesce((p_arguments->>'online_booking_enabled')::boolean,true))
     ON CONFLICT(business_id,service_code) DO UPDATE SET name=excluded.name,description=excluded.description,price=excluded.price,currency=excluded.currency,duration_minutes=excluded.duration_minutes,
       buffer_before_minutes=excluded.buffer_before_minutes,buffer_after_minutes=excluded.buffer_after_minutes,display_order=excluded.display_order,active=excluded.active,online_booking_enabled=excluded.online_booking_enabled,updated_at=now()
     RETURNING id INTO sid; r:=jsonb_build_object('ok',true,'code','SERVICE_UPSERTED','service_id',sid);

   ELSIF a='UPSERT_PROFESSIONAL' THEN
     pro:=coalesce(nullif(p_arguments->>'id','')::uuid,gen_random_uuid());
     INSERT INTO core.professionals(id,business_id,professional_code,name,display_name,description,active,online_booking_enabled,display_order,calendar_provider,external_calendar_id)
     VALUES(pro,p_business_id,p_arguments->>'professional_code',p_arguments->>'name',p_arguments->>'display_name',p_arguments->>'description',coalesce((p_arguments->>'active')::boolean,true),coalesce((p_arguments->>'online_booking_enabled')::boolean,true),coalesce((p_arguments->>'display_order')::int,0),p_arguments->>'calendar_provider',p_arguments->>'external_calendar_id')
     ON CONFLICT(business_id,professional_code) DO UPDATE SET name=excluded.name,display_name=excluded.display_name,description=excluded.description,active=excluded.active,online_booking_enabled=excluded.online_booking_enabled,display_order=excluded.display_order,calendar_provider=excluded.calendar_provider,external_calendar_id=excluded.external_calendar_id,updated_at=now()
     RETURNING id INTO pro; r:=jsonb_build_object('ok',true,'code','PROFESSIONAL_UPSERTED','professional_id',pro);

   ELSIF a='SET_PROFESSIONAL_SERVICE' THEN
     pro:=(p_arguments->>'professional_id')::uuid; sid:=(p_arguments->>'service_id')::uuid;
     INSERT INTO core.professional_services(business_id,professional_id,service_id,active,online_booking_enabled,price_override,duration_minutes_override)
     VALUES(p_business_id,pro,sid,coalesce((p_arguments->>'active')::boolean,true),coalesce((p_arguments->>'online_booking_enabled')::boolean,true),nullif(p_arguments->>'price_override','')::numeric,nullif(p_arguments->>'duration_minutes_override','')::int)
     ON CONFLICT(business_id,professional_id,service_id) DO UPDATE SET active=excluded.active,online_booking_enabled=excluded.online_booking_enabled,price_override=excluded.price_override,duration_minutes_override=excluded.duration_minutes_override,updated_at=now();
     r:=jsonb_build_object('ok',true,'code','PROFESSIONAL_SERVICE_UPDATED');

   ELSIF a='UPSERT_PRODUCT' THEN
     r:=core.execute_control_plane_action_v2(p_actor_user_id,p_business_id,'UPSERT_PRODUCT',p_arguments,p_idempotency_key,p_execution_ref);
   ELSIF a='CREATE_CAMPAIGN' THEN
     r:=core.execute_control_plane_action_v2(p_actor_user_id,p_business_id,'CREATE_CAMPAIGN',p_arguments,p_idempotency_key,p_execution_ref);
   ELSIF a='UPDATE_CAMPAIGN_STATUS' THEN
     UPDATE core.campaigns SET status=upper(p_arguments->>'status'),updated_at=now()
     WHERE id=(p_arguments->>'campaign_id')::uuid AND business_id=p_business_id
       AND upper(p_arguments->>'status') IN('SCHEDULED','RUNNING','PAUSED','CANCELLED');
     r:=jsonb_build_object('ok',true,'code','CAMPAIGN_STATUS_UPDATED');
   ELSIF a='UPSERT_KNOWLEDGE' THEN
     r:=core.upsert_knowledge_document_v1(p_business_id,p_arguments->>'external_key',p_arguments->>'title',p_arguments->>'content',coalesce(p_arguments->'metadata','{}'::jsonb),p_execution_ref);
   ELSIF a='UPDATE_AUTOMATION_POLICY' THEN
     INSERT INTO core.automation_policies(business_id,policy_type,enabled,config)
     VALUES(p_business_id,upper(p_arguments->>'policy_type'),coalesce((p_arguments->>'enabled')::boolean,true),coalesce(p_arguments->'config','{}'::jsonb))
     ON CONFLICT(business_id,policy_type) DO UPDATE SET enabled=excluded.enabled,config=excluded.config,updated_at=now();
     r:=jsonb_build_object('ok',true,'code','AUTOMATION_POLICY_UPDATED');
   ELSIF a='SET_MARKETING_CONSENT' THEN
     r:=core.set_marketing_consent_v2(p_business_id,(p_arguments->>'customer_id')::uuid,(p_arguments->>'marketing_opt_in')::boolean,'CONTROL_PLANE');
   ELSIF a='SET_CONVERSATION_MODE' THEN
     UPDATE core.conversations SET automation_mode=upper(p_arguments->>'mode'),updated_at=now()
     WHERE business_id=p_business_id AND id=(p_arguments->>'conversation_id')::uuid AND upper(p_arguments->>'mode') IN('AUTO','HUMAN');
     r:=jsonb_build_object('ok',true,'code','CONVERSATION_MODE_UPDATED');
   ELSIF a='ACK_INCIDENT' THEN
     UPDATE core.automation_incidents SET status='ACKNOWLEDGED' WHERE business_id=p_business_id AND id=(p_arguments->>'incident_id')::bigint;
     r:=jsonb_build_object('ok',true,'code','INCIDENT_ACKNOWLEDGED');
   ELSIF a='RESOLVE_INCIDENT' THEN
     UPDATE core.automation_incidents SET status='RESOLVED',resolved_at=now() WHERE business_id=p_business_id AND id=(p_arguments->>'incident_id')::bigint;
     r:=jsonb_build_object('ok',true,'code','INCIDENT_RESOLVED');
   ELSIF a='UPSERT_MEMBER' THEN
     INSERT INTO core.business_memberships(business_id,user_id,role,professional_id,active)
     VALUES(p_business_id,(p_arguments->>'user_id')::uuid,upper(p_arguments->>'role'),nullif(p_arguments->>'professional_id','')::uuid,coalesce((p_arguments->>'active')::boolean,true))
     ON CONFLICT(business_id,user_id) DO UPDATE SET role=excluded.role,professional_id=excluded.professional_id,active=excluded.active,updated_at=now();
     r:=jsonb_build_object('ok',true,'code','MEMBER_UPSERTED');
   ELSIF a='UPDATE_SETTINGS' THEN
     UPDATE core.business_settings SET
       reminders_enabled=CASE WHEN p_arguments?'reminders_enabled' THEN (p_arguments->>'reminders_enabled')::boolean ELSE reminders_enabled END,
       reminder_first_hours_before=CASE WHEN p_arguments?'reminder_first_hours_before' THEN (p_arguments->>'reminder_first_hours_before')::int ELSE reminder_first_hours_before END,
       reminder_second_hours_before=CASE WHEN p_arguments?'reminder_second_hours_before' THEN (p_arguments->>'reminder_second_hours_before')::int ELSE reminder_second_hours_before END,
       waitlist_enabled=CASE WHEN p_arguments?'waitlist_enabled' THEN (p_arguments->>'waitlist_enabled')::boolean ELSE waitlist_enabled END,
       reactivation_enabled=CASE WHEN p_arguments?'reactivation_enabled' THEN (p_arguments->>'reactivation_enabled')::boolean ELSE reactivation_enabled END,
       cancellation_enabled=CASE WHEN p_arguments?'cancellation_enabled' THEN (p_arguments->>'cancellation_enabled')::boolean ELSE cancellation_enabled END,
       rescheduling_enabled=CASE WHEN p_arguments?'rescheduling_enabled' THEN (p_arguments->>'rescheduling_enabled')::boolean ELSE rescheduling_enabled END,
       extra_settings=CASE WHEN p_arguments?'extra_settings' THEN coalesce(extra_settings,'{}'::jsonb)||coalesce(p_arguments->'extra_settings','{}'::jsonb) ELSE extra_settings END,
       updated_at=now()
     WHERE business_id=p_business_id;
     IF p_arguments?'brand' THEN
       UPDATE core.business_brand_profiles SET
         assistant_name=coalesce(p_arguments#>>'{brand,assistant_name}',assistant_name),
         brand_personality=coalesce(p_arguments#>>'{brand,brand_personality}',brand_personality),
         default_treatment=coalesce(p_arguments#>>'{brand,default_treatment}',default_treatment),
         allow_slang=coalesce((p_arguments#>>'{brand,allow_slang}')::boolean,allow_slang),
         emoji_max_per_message=coalesce((p_arguments#>>'{brand,emoji_max_per_message}')::smallint,emoji_max_per_message),updated_at=now()
       WHERE business_id=p_business_id;
     END IF;
     r:=jsonb_build_object('ok',true,'code','SETTINGS_UPDATED');
   ELSE
     r:=jsonb_build_object('ok',false,'code','ACTION_NOT_SUPPORTED','action',a);
   END IF;
 END IF;

 INSERT INTO core.audit_log(business_id,actor_user_id,actor_type,action,request_id,payload)
 VALUES(biz,p_actor_user_id,'USER',a,p_execution_ref,jsonb_build_object('idempotency_key',p_idempotency_key,'arguments',coalesce(p_arguments,'{}'::jsonb),'result',r));
 RETURN r;
EXCEPTION WHEN unique_violation THEN RETURN jsonb_build_object('ok',false,'code','UNIQUE_CONSTRAINT_VIOLATION');
WHEN invalid_text_representation OR check_violation OR foreign_key_violation THEN RETURN jsonb_build_object('ok',false,'code','INVALID_ARGUMENT','detail',SQLERRM);
END;
$function$;
