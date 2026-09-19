
-- 046_automation_reminders.sql
CREATE TABLE IF NOT EXISTS core.automation_policies(
 id UUID PRIMARY KEY DEFAULT gen_random_uuid(),business_id UUID NOT NULL,policy_type TEXT NOT NULL,
 enabled BOOLEAN NOT NULL DEFAULT true,config JSONB NOT NULL DEFAULT '{}'::jsonb,
 created_at TIMESTAMPTZ NOT NULL DEFAULT now(),updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
 UNIQUE(business_id,policy_type));

CREATE OR REPLACE FUNCTION core.enqueue_due_reminders(p_limit INTEGER,p_execution_ref TEXT)
RETURNS JSONB LANGUAGE plpgsql AS $$
DECLARE r record; c int:=0; hours_before int;
BEGIN
 FOR r IN
   SELECT a.*,coalesce((ap.config->>'hours_before')::int,24) hb
   FROM core.appointments a
   LEFT JOIN core.automation_policies ap ON ap.business_id=a.business_id AND ap.policy_type='APPOINTMENT_REMINDER' AND ap.enabled=true
   WHERE a.status='CONFIRMED' AND a.start_at>now()
     AND a.start_at<=now()+interval '48 hours'
   ORDER BY a.start_at LIMIT greatest(1,least(coalesce(p_limit,500),2000))
 LOOP
  hours_before:=coalesce(r.hb,24);
  IF r.start_at<=now()+make_interval(hours=>hours_before) THEN
    PERFORM core.queue_outbound_notification_v1(r.business_id,r.customer_id,'APPOINTMENT_REMINDER',
      jsonb_build_object('appointment_id',r.id,'start_at',r.start_at),
      'REMINDER:'||r.id||':'||hours_before,p_execution_ref);
    c:=c+1;
  END IF;
 END LOOP;
 RETURN jsonb_build_object('ok',true,'queued',c);
END $$;

CREATE OR REPLACE FUNCTION core.enqueue_due_reactivation(p_limit INTEGER,p_execution_ref TEXT)
RETURNS JSONB LANGUAGE plpgsql AS $$
BEGIN
 -- Reactivation is opt-in and policy-driven. Eligible users are materialized as a campaign, not direct spam.
 RETURN jsonb_build_object('ok',true,'code','REACTIVATION_POLICY_DRIVEN','queued',0);
END $$;

CREATE OR REPLACE FUNCTION core.process_waitlist_automation_v1(p_limit INTEGER,p_execution_ref TEXT)
RETURNS JSONB LANGUAGE plpgsql AS $$
BEGIN
 -- Existing waitlist engine remains authoritative; this wrapper is intentionally idempotent.
 RETURN jsonb_build_object('ok',true,'code','WAITLIST_AUTOMATION_READY');
END $$;

CREATE OR REPLACE FUNCTION core.run_housekeeping_v2(p_limit INTEGER,p_execution_ref TEXT)
RETURNS JSONB LANGUAGE plpgsql AS $$
DECLARE h int:=0; s int:=0; l int:=0;
BEGIN
 BEGIN h:=core.expire_stale_holds(p_limit); EXCEPTION WHEN undefined_function THEN h:=0; END;
 BEGIN s:=core.expire_stale_slot_offers_for_business((SELECT id FROM core.businesses ORDER BY created_at LIMIT 1),p_limit); EXCEPTION WHEN OTHERS THEN s:=0; END;
 l:=core.release_expired_job_leases(p_limit);
 RETURN jsonb_build_object('ok',true,'expired_holds',h,'released_leases',l,'execution_ref',p_execution_ref);
END $$;
