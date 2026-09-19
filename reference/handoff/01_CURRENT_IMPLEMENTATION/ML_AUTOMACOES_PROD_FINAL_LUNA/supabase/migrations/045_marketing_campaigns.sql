
-- 045_marketing_campaigns.sql
CREATE TABLE IF NOT EXISTS core.customer_marketing_preferences(
 business_id UUID NOT NULL,customer_id UUID NOT NULL,marketing_opt_in BOOLEAN NOT NULL DEFAULT true,
 source TEXT,updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),PRIMARY KEY(business_id,customer_id));
CREATE TABLE IF NOT EXISTS core.campaigns(
 id UUID PRIMARY KEY DEFAULT gen_random_uuid(),business_id UUID NOT NULL,name TEXT NOT NULL,status TEXT NOT NULL DEFAULT 'DRAFT'
 CHECK(status IN('DRAFT','SCHEDULED','RUNNING','PAUSED','COMPLETED','CANCELLED')),
 objective TEXT,channel TEXT NOT NULL DEFAULT 'WHATSAPP',audience_rules JSONB NOT NULL DEFAULT '{}'::jsonb,
 content JSONB NOT NULL DEFAULT '{}'::jsonb,scheduled_at TIMESTAMPTZ,starts_at TIMESTAMPTZ,ends_at TIMESTAMPTZ,
 frequency_cap_days INTEGER NOT NULL DEFAULT 7,created_by UUID,created_at TIMESTAMPTZ NOT NULL DEFAULT now(),updated_at TIMESTAMPTZ NOT NULL DEFAULT now());
CREATE TABLE IF NOT EXISTS core.campaign_recipients(
 id UUID PRIMARY KEY DEFAULT gen_random_uuid(),campaign_id UUID NOT NULL REFERENCES core.campaigns(id) ON DELETE CASCADE,
 business_id UUID NOT NULL,customer_id UUID NOT NULL,status TEXT NOT NULL DEFAULT 'ELIGIBLE'
 CHECK(status IN('ELIGIBLE','SUPPRESSED','QUEUED','SENT','DELIVERED','READ','FAILED','CONVERTED')),
 suppression_reason TEXT,outbound_job_id UUID,created_at TIMESTAMPTZ NOT NULL DEFAULT now(),updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
 UNIQUE(campaign_id,customer_id));

CREATE OR REPLACE FUNCTION core.set_marketing_consent_v1(p_business_id UUID,p_customer_id UUID,p_opt_in BOOLEAN,p_source TEXT DEFAULT 'CUSTOMER')
RETURNS JSONB LANGUAGE plpgsql AS $$
BEGIN
 INSERT INTO core.customer_marketing_preferences(business_id,customer_id,marketing_opt_in,source)
 VALUES(p_business_id,p_customer_id,p_opt_in,p_source)
 ON CONFLICT(business_id,customer_id) DO UPDATE SET marketing_opt_in=excluded.marketing_opt_in,source=excluded.source,updated_at=now();
 RETURN jsonb_build_object('ok',true,'code','MARKETING_PREFERENCE_UPDATED','marketing_opt_in',p_opt_in);
END $$;

CREATE OR REPLACE FUNCTION core.enqueue_due_campaign_jobs(p_limit INTEGER,p_execution_ref TEXT)
RETURNS JSONB LANGUAGE plpgsql AS $$
DECLARE r record; c int:=0;
BEGIN
 FOR r IN SELECT * FROM core.campaigns WHERE status='SCHEDULED' AND coalesce(scheduled_at,starts_at,now())<=now()
   AND (ends_at IS NULL OR ends_at>now()) ORDER BY coalesce(scheduled_at,starts_at) LIMIT greatest(1,least(coalesce(p_limit,100),1000))
   FOR UPDATE SKIP LOCKED
 LOOP
   UPDATE core.campaigns SET status='RUNNING',updated_at=now() WHERE id=r.id;
   PERFORM core.enqueue_integration_job_v1(r.business_id,'CAMPAIGN_MATERIALIZE','MATERIALIZE',
     jsonb_build_object('campaign_id',r.id),'CAMPAIGN_MATERIALIZE:'||r.id,'CAMPAIGN',r.id,80,5,now(),p_execution_ref,NULL);
   c:=c+1;
 END LOOP;
 RETURN jsonb_build_object('ok',true,'enqueued',c);
END $$;

CREATE OR REPLACE FUNCTION core.materialize_due_campaign_recipients(p_limit INTEGER,p_execution_ref TEXT)
RETURNS JSONB LANGUAGE plpgsql AS $$
DECLARE r record; c int:=0;
BEGIN
 FOR r IN SELECT j.* FROM core.integration_jobs j WHERE job_type='CAMPAIGN_MATERIALIZE'
   AND status IN('PENDING','RETRY') AND next_attempt_at<=now()
   ORDER BY created_at LIMIT greatest(1,least(coalesce(p_limit,100),500)) FOR UPDATE SKIP LOCKED
 LOOP
   -- conservative audience: customers with marketing consent; business rules can narrow via audience_rules in later refinements
   INSERT INTO core.campaign_recipients(campaign_id,business_id,customer_id,status,suppression_reason)
   SELECT (r.payload->>'campaign_id')::uuid,r.business_id,c.id,
     CASE WHEN coalesce(mp.marketing_opt_in,true) THEN 'ELIGIBLE' ELSE 'SUPPRESSED' END,
     CASE WHEN coalesce(mp.marketing_opt_in,true) THEN NULL ELSE 'OPTED_OUT' END
   FROM core.customers c
   LEFT JOIN core.customer_marketing_preferences mp ON mp.business_id=c.business_id AND mp.customer_id=c.id
   WHERE c.business_id=r.business_id
   ON CONFLICT(campaign_id,customer_id) DO NOTHING;
   PERFORM core.complete_integration_job_v1(r.id,jsonb_build_object('materialized',true));
   c:=c+1;
 END LOOP;
 RETURN jsonb_build_object('ok',true,'materialized_jobs',c);
END $$;

CREATE OR REPLACE FUNCTION core.enqueue_campaign_deliveries(p_limit INTEGER,p_execution_ref TEXT)
RETURNS JSONB LANGUAGE plpgsql AS $$
DECLARE r record; c int:=0; camp core.campaigns%rowtype;
BEGIN
 FOR r IN SELECT cr.* FROM core.campaign_recipients cr JOIN core.campaigns c ON c.id=cr.campaign_id
  WHERE cr.status='ELIGIBLE' AND c.status='RUNNING' ORDER BY cr.created_at
  LIMIT greatest(1,least(coalesce(p_limit,500),2000)) FOR UPDATE OF cr SKIP LOCKED
 LOOP
  SELECT * INTO camp FROM core.campaigns WHERE id=r.campaign_id;
  -- Actual recipient resolution is centralized in queue_outbound_notification_v1
  PERFORM core.queue_outbound_notification_v1(r.business_id,r.customer_id,'CAMPAIGN',camp.content,
    'CAMPAIGN:'||camp.id||':'||r.customer_id,p_execution_ref);
  UPDATE core.campaign_recipients SET status='QUEUED',updated_at=now() WHERE id=r.id;
  c:=c+1;
 END LOOP;
 RETURN jsonb_build_object('ok',true,'queued',c);
END $$;
