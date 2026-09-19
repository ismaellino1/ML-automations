-- ML AUTOMAÇÕES — PROD FINAL LUNA
-- ONE SHOT OVERLAY: run ONLY after the verified 001-042 base/preflight.
-- Generated from canonical migrations 043-057 in numeric order.


-- ============================================================
-- SOURCE: 043_prod_job_queue.sql
-- ============================================================

-- 043_prod_job_queue.sql
CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE SCHEMA IF NOT EXISTS private;

CREATE TABLE IF NOT EXISTS core.integration_jobs (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id UUID NOT NULL,
  job_type TEXT NOT NULL,
  operation TEXT NOT NULL,
  subject_type TEXT,
  subject_id UUID,
  dedupe_key TEXT,
  correlation_id TEXT,
  causal_job_id UUID REFERENCES core.integration_jobs(id) ON DELETE SET NULL,
  payload JSONB NOT NULL DEFAULT '{}'::jsonb,
  status TEXT NOT NULL DEFAULT 'PENDING' CHECK (status IN ('PENDING','RUNNING','SUCCEEDED','RETRY','DEAD')),
  priority SMALLINT NOT NULL DEFAULT 100,
  attempts INTEGER NOT NULL DEFAULT 0,
  max_attempts INTEGER NOT NULL DEFAULT 8 CHECK (max_attempts BETWEEN 1 AND 50),
  next_attempt_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  lease_owner TEXT,
  lease_expires_at TIMESTAMPTZ,
  last_error TEXT,
  provider_response JSONB,
  completed_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX IF NOT EXISTS uq_integration_jobs_dedupe
ON core.integration_jobs(business_id,job_type,dedupe_key) WHERE dedupe_key IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_integration_jobs_claim
ON core.integration_jobs(job_type,status,next_attempt_at,priority,created_at)
WHERE status IN ('PENDING','RETRY');
CREATE INDEX IF NOT EXISTS idx_integration_jobs_lease
ON core.integration_jobs(lease_expires_at) WHERE status='RUNNING';

CREATE TABLE IF NOT EXISTS core.integration_job_attempts (
  id BIGSERIAL PRIMARY KEY,
  job_id UUID NOT NULL REFERENCES core.integration_jobs(id) ON DELETE CASCADE,
  attempt_no INTEGER NOT NULL,
  worker_ref TEXT,
  started_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  finished_at TIMESTAMPTZ,
  outcome TEXT,
  error TEXT,
  provider_response JSONB
);

CREATE OR REPLACE FUNCTION core.enqueue_integration_job_v1(
 p_business_id UUID,p_job_type TEXT,p_operation TEXT,p_payload JSONB,
 p_dedupe_key TEXT DEFAULT NULL,p_subject_type TEXT DEFAULT NULL,p_subject_id UUID DEFAULT NULL,
 p_priority SMALLINT DEFAULT 100,p_max_attempts INTEGER DEFAULT 8,p_next_attempt_at TIMESTAMPTZ DEFAULT now(),
 p_correlation_id TEXT DEFAULT NULL,p_causal_job_id UUID DEFAULT NULL
) RETURNS UUID LANGUAGE plpgsql AS $$
DECLARE v_id UUID;
BEGIN
 INSERT INTO core.integration_jobs(business_id,job_type,operation,payload,dedupe_key,subject_type,subject_id,
   priority,max_attempts,next_attempt_at,correlation_id,causal_job_id)
 VALUES(p_business_id,upper(p_job_type),upper(p_operation),coalesce(p_payload,'{}'::jsonb),
   nullif(btrim(p_dedupe_key),''),p_subject_type,p_subject_id,coalesce(p_priority,100),
   greatest(1,coalesce(p_max_attempts,8)),coalesce(p_next_attempt_at,now()),p_correlation_id,p_causal_job_id)
 ON CONFLICT (business_id,job_type,dedupe_key) WHERE dedupe_key IS NOT NULL
 DO UPDATE SET updated_at=now()
 RETURNING id INTO v_id;
 RETURN v_id;
END $$;

CREATE OR REPLACE FUNCTION core.claim_integration_jobs_v1(
 p_job_type TEXT,p_limit INTEGER,p_worker_ref TEXT,p_lease_seconds INTEGER DEFAULT 120
) RETURNS TABLE(job JSONB) LANGUAGE plpgsql AS $$
BEGIN
 RETURN QUERY
 WITH picked AS (
   SELECT id FROM core.integration_jobs
   WHERE job_type=upper(p_job_type)
     AND status IN ('PENDING','RETRY')
     AND next_attempt_at<=now()
     AND (lease_expires_at IS NULL OR lease_expires_at<now())
   ORDER BY priority ASC,next_attempt_at ASC,created_at ASC
   FOR UPDATE SKIP LOCKED
   LIMIT greatest(1,least(coalesce(p_limit,10),200))
 ), upd AS (
   UPDATE core.integration_jobs j
   SET status='RUNNING',attempts=j.attempts+1,lease_owner=p_worker_ref,
       lease_expires_at=now()+make_interval(secs=>greatest(30,least(coalesce(p_lease_seconds,120),1800))),
       updated_at=now()
   FROM picked p WHERE j.id=p.id
   RETURNING j.*
 )
 SELECT to_jsonb(upd) FROM upd;
END $$;

CREATE OR REPLACE FUNCTION core.complete_integration_job_v1(
 p_job_id UUID,p_provider_response JSONB DEFAULT '{}'::jsonb
) RETURNS JSONB LANGUAGE plpgsql AS $$
DECLARE v core.integration_jobs%rowtype;
BEGIN
 UPDATE core.integration_jobs SET status='SUCCEEDED',provider_response=coalesce(p_provider_response,'{}'::jsonb),
   completed_at=now(),lease_owner=NULL,lease_expires_at=NULL,updated_at=now()
 WHERE id=p_job_id AND status='RUNNING' RETURNING * INTO v;
 IF NOT FOUND THEN RETURN jsonb_build_object('ok',false,'code','JOB_NOT_RUNNING'); END IF;
 INSERT INTO core.integration_job_attempts(job_id,attempt_no,worker_ref,finished_at,outcome,provider_response)
 VALUES(v.id,v.attempts,v.lease_owner,now(),'SUCCEEDED',p_provider_response);
 RETURN jsonb_build_object('ok',true,'code','JOB_COMPLETED','job_id',v.id);
END $$;

CREATE OR REPLACE FUNCTION core.fail_integration_job_v1(
 p_job_id UUID,p_error TEXT,p_provider_response JSONB DEFAULT '{}'::jsonb
) RETURNS JSONB LANGUAGE plpgsql AS $$
DECLARE v core.integration_jobs%rowtype; v_delay INTEGER; v_new TEXT;
BEGIN
 SELECT * INTO v FROM core.integration_jobs WHERE id=p_job_id FOR UPDATE;
 IF NOT FOUND THEN RETURN jsonb_build_object('ok',false,'code','JOB_NOT_FOUND'); END IF;
 v_delay := CASE
   WHEN v.attempts<=1 THEN 5 WHEN v.attempts=2 THEN 15 WHEN v.attempts=3 THEN 60
   WHEN v.attempts=4 THEN 300 WHEN v.attempts=5 THEN 900 ELSE 3600 END;
 v_new := CASE WHEN v.attempts>=v.max_attempts THEN 'DEAD' ELSE 'RETRY' END;
 UPDATE core.integration_jobs SET status=v_new,last_error=left(coalesce(p_error,'UNKNOWN'),4000),
   provider_response=coalesce(p_provider_response,'{}'::jsonb),
   next_attempt_at=CASE WHEN v_new='RETRY' THEN now()+make_interval(secs=>v_delay) ELSE next_attempt_at END,
   completed_at=CASE WHEN v_new='DEAD' THEN now() ELSE completed_at END,
   lease_owner=NULL,lease_expires_at=NULL,updated_at=now()
 WHERE id=p_job_id;
 INSERT INTO core.integration_job_attempts(job_id,attempt_no,worker_ref,finished_at,outcome,error,provider_response)
 VALUES(v.id,v.attempts,v.lease_owner,now(),v_new,p_error,p_provider_response);
 RETURN jsonb_build_object('ok',true,'code',CASE WHEN v_new='DEAD' THEN 'JOB_DEAD_LETTERED' ELSE 'JOB_RETRY_SCHEDULED' END,
   'job_id',v.id,'status',v_new,'next_attempt_at',CASE WHEN v_new='RETRY' THEN now()+make_interval(secs=>v_delay) ELSE NULL END);
END $$;

CREATE OR REPLACE FUNCTION core.release_expired_job_leases(p_limit INTEGER DEFAULT 1000)
RETURNS INTEGER LANGUAGE plpgsql AS $$
DECLARE v INTEGER;
BEGIN
 WITH x AS (
  SELECT id FROM core.integration_jobs WHERE status='RUNNING' AND lease_expires_at<now()
  ORDER BY lease_expires_at FOR UPDATE SKIP LOCKED LIMIT greatest(1,least(coalesce(p_limit,1000),10000))
 ), u AS (
  UPDATE core.integration_jobs j SET status='RETRY',lease_owner=NULL,lease_expires_at=NULL,next_attempt_at=now(),updated_at=now()
  FROM x WHERE j.id=x.id RETURNING j.id
 ) SELECT count(*)::int INTO v FROM u;
 RETURN coalesce(v,0);
END $$;


-- ============================================================
-- SOURCE: 044_catalog_knowledge_media.sql
-- ============================================================

-- 044_catalog_knowledge_media.sql
CREATE TABLE IF NOT EXISTS core.product_categories(
 id UUID PRIMARY KEY DEFAULT gen_random_uuid(),business_id UUID NOT NULL,name TEXT NOT NULL,slug TEXT NOT NULL,
 description TEXT,active BOOLEAN NOT NULL DEFAULT true,display_order INTEGER NOT NULL DEFAULT 0,
 created_at TIMESTAMPTZ NOT NULL DEFAULT now(),updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
 UNIQUE(business_id,slug));
CREATE TABLE IF NOT EXISTS core.products(
 id UUID PRIMARY KEY DEFAULT gen_random_uuid(),business_id UUID NOT NULL,category_id UUID REFERENCES core.product_categories(id) ON DELETE SET NULL,
 sku TEXT,name TEXT NOT NULL,description TEXT,price NUMERIC(12,2),currency CHAR(3) NOT NULL DEFAULT 'BRL',
 stock_status TEXT NOT NULL DEFAULT 'UNKNOWN' CHECK(stock_status IN('IN_STOCK','LOW_STOCK','OUT_OF_STOCK','UNKNOWN')),
 active BOOLEAN NOT NULL DEFAULT true,tags TEXT[] NOT NULL DEFAULT '{}',attributes JSONB NOT NULL DEFAULT '{}'::jsonb,
 created_at TIMESTAMPTZ NOT NULL DEFAULT now(),updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
 UNIQUE(business_id,sku));
CREATE INDEX IF NOT EXISTS idx_products_business_active ON core.products(business_id,active,name);

CREATE TABLE IF NOT EXISTS core.knowledge_documents(
 id UUID PRIMARY KEY DEFAULT gen_random_uuid(),business_id UUID NOT NULL,external_key TEXT NOT NULL,title TEXT NOT NULL,
 content TEXT NOT NULL,metadata JSONB NOT NULL DEFAULT '{}'::jsonb,active BOOLEAN NOT NULL DEFAULT true,
 search_vector TSVECTOR GENERATED ALWAYS AS (to_tsvector('simple',coalesce(title,'')||' '||coalesce(content,''))) STORED,
 created_at TIMESTAMPTZ NOT NULL DEFAULT now(),updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
 UNIQUE(business_id,external_key));
CREATE INDEX IF NOT EXISTS idx_knowledge_fts ON core.knowledge_documents USING GIN(search_vector);

CREATE TABLE IF NOT EXISTS core.media_assets(
 id UUID PRIMARY KEY DEFAULT gen_random_uuid(),business_id UUID NOT NULL,message_id UUID,
 provider TEXT NOT NULL DEFAULT 'META',media_id TEXT NOT NULL,mime_type TEXT,filename TEXT,caption TEXT,
 processing_status TEXT NOT NULL DEFAULT 'PENDING' CHECK(processing_status IN('PENDING','PROCESSING','READY','FAILED')),
 transcript TEXT,visual_description TEXT,document_text TEXT,summary TEXT,language TEXT,confidence NUMERIC(5,4),
 safety_notes JSONB NOT NULL DEFAULT '[]'::jsonb,provider_metadata JSONB NOT NULL DEFAULT '{}'::jsonb,
 created_at TIMESTAMPTZ NOT NULL DEFAULT now(),updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
 UNIQUE(business_id,provider,media_id));

CREATE OR REPLACE FUNCTION core.upsert_knowledge_document_v1(
 p_business_id UUID,p_external_key TEXT,p_title TEXT,p_content TEXT,p_metadata JSONB DEFAULT '{}'::jsonb,p_execution_ref TEXT DEFAULT NULL
) RETURNS JSONB LANGUAGE plpgsql AS $$
DECLARE v_id UUID;
BEGIN
 INSERT INTO core.knowledge_documents(business_id,external_key,title,content,metadata)
 VALUES(p_business_id,p_external_key,p_title,p_content,coalesce(p_metadata,'{}'::jsonb))
 ON CONFLICT(business_id,external_key) DO UPDATE SET title=excluded.title,content=excluded.content,
 metadata=excluded.metadata,active=true,updated_at=now()
 RETURNING id INTO v_id;
 RETURN jsonb_build_object('ok',true,'code','KNOWLEDGE_UPSERTED','document_id',v_id);
END $$;

CREATE OR REPLACE FUNCTION core.search_business_knowledge_v1(p_business_id UUID,p_query TEXT,p_limit INTEGER DEFAULT 8)
RETURNS JSONB LANGUAGE sql STABLE AS $$
SELECT coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb) FROM (
 SELECT id,title,left(content,3000) content,metadata,
        ts_rank(search_vector,plainto_tsquery('simple',coalesce(p_query,''))) rank
 FROM core.knowledge_documents
 WHERE business_id=p_business_id AND active=true
   AND (nullif(btrim(p_query),'') IS NULL OR search_vector @@ plainto_tsquery('simple',p_query))
 ORDER BY rank DESC,updated_at DESC LIMIT greatest(1,least(coalesce(p_limit,8),20))
) x $$;

CREATE OR REPLACE FUNCTION core.get_catalog_context_v1(p_business_id UUID,p_limit INTEGER DEFAULT 50)
RETURNS JSONB LANGUAGE sql STABLE AS $$
SELECT coalesce(jsonb_agg(jsonb_build_object('product_id',p.id,'name',p.name,'description',p.description,
 'price',p.price,'currency',p.currency,'stock_status',p.stock_status,'tags',p.tags,'attributes',p.attributes)
 ORDER BY p.name),'[]'::jsonb)
FROM core.products p WHERE p.business_id=p_business_id AND p.active=true
LIMIT greatest(1,least(coalesce(p_limit,50),100)) $$;

CREATE OR REPLACE FUNCTION core.claim_media_processing_batch(p_limit INTEGER,p_worker_ref TEXT)
RETURNS TABLE(job JSONB) LANGUAGE sql AS $$
SELECT jsonb_build_object(
 'job_id',j.id,'business_id',j.business_id,'media_asset_id',(j.payload->>'media_asset_id')::uuid,
 'media_id',j.payload->>'media_id','media_type',j.payload->>'media_type','mime_type',j.payload->>'mime_type',
 'filename',j.payload->>'filename','caption',j.payload->>'caption','message_id',j.payload->>'message_id',
 'graph_api_version',coalesce(j.payload->>'graph_api_version','v26.0'))
FROM core.claim_integration_jobs_v1('MEDIA_PROCESS',p_limit,p_worker_ref,300) q(job)
JOIN LATERAL jsonb_to_record(q.job) AS j0(id uuid,business_id uuid,payload jsonb) ON true
JOIN core.integration_jobs j ON j.id=j0.id $$;

CREATE OR REPLACE FUNCTION core.complete_media_processing_job(p_job_id UUID,p_result JSONB)
RETURNS JSONB LANGUAGE plpgsql AS $$
DECLARE j core.integration_jobs%rowtype; a_id UUID; a core.media_assets%rowtype; conv_payload JSONB;
BEGIN
 SELECT * INTO j FROM core.integration_jobs WHERE id=p_job_id FOR UPDATE;
 IF NOT FOUND THEN RETURN jsonb_build_object('ok',false,'code','JOB_NOT_FOUND'); END IF;
 a_id:=(j.payload->>'media_asset_id')::uuid;
 UPDATE core.media_assets SET processing_status='READY',
  transcript=nullif(p_result->>'transcript',''),visual_description=nullif(p_result->>'visual_description',''),
  document_text=nullif(p_result->>'document_text',''),summary=nullif(p_result->>'summary',''),
  language=nullif(p_result->>'language',''),confidence=nullif(p_result->>'confidence','')::numeric,
  safety_notes=coalesce(p_result->'safety_notes','[]'::jsonb),updated_at=now()
 WHERE id=a_id RETURNING * INTO a;
 conv_payload := j.payload->'conversation_payload' ||
   jsonb_build_object('media_context',jsonb_build_object('media_asset_id',a.id,'transcript',a.transcript,
   'visual_description',a.visual_description,'document_text',a.document_text,'summary',a.summary,
   'language',a.language,'confidence',a.confidence,'safety_notes',a.safety_notes));
 PERFORM core.enqueue_integration_job_v1(j.business_id,'CONVERSATION_TURN','PROCESS',conv_payload,
  'CONVERSATION:'||(j.payload->>'message_id'),'MESSAGE',(j.payload->>'message_id')::uuid,50,5,now(),j.correlation_id,j.id);
 PERFORM core.complete_integration_job_v1(p_job_id,p_result);
 RETURN jsonb_build_object('ok',true,'code','MEDIA_READY','media_asset_id',a_id);
END $$;

CREATE OR REPLACE FUNCTION core.fail_media_processing_job(p_job_id UUID,p_error TEXT,p_payload JSONB)
RETURNS JSONB LANGUAGE sql AS $$
SELECT core.fail_integration_job_v1(p_job_id,p_error,p_payload) $$;


-- ============================================================
-- SOURCE: 045_marketing_campaigns.sql
-- ============================================================

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


-- ============================================================
-- SOURCE: 046_automation_reminders.sql
-- ============================================================
-- 046_automation_policy_foundation.sql
-- Production foundation only. There are deliberately NO provisional/no-op functions here.
-- Final reminder/reactivation/campaign functions are defined in 052.
-- Final waitlist automation is defined in 053.

CREATE TABLE IF NOT EXISTS core.automation_policies (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    business_id UUID NOT NULL REFERENCES core.businesses(id) ON DELETE CASCADE,
    policy_type TEXT NOT NULL,
    enabled BOOLEAN NOT NULL DEFAULT TRUE,
    config JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (business_id, policy_type)
);

CREATE INDEX IF NOT EXISTS idx_automation_policies_business_enabled
ON core.automation_policies (business_id, enabled, policy_type);

DROP TRIGGER IF EXISTS trg_automation_policies_updated_at
ON core.automation_policies;

CREATE TRIGGER trg_automation_policies_updated_at
BEFORE UPDATE ON core.automation_policies
FOR EACH ROW
EXECUTE FUNCTION core.set_updated_at();


-- ============================================================
-- SOURCE: 047_rbac_control_plane.sql
-- ============================================================

-- 047_rbac_control_plane.sql
CREATE TABLE IF NOT EXISTS core.platform_users(
 user_id UUID PRIMARY KEY,display_name TEXT,created_at TIMESTAMPTZ NOT NULL DEFAULT now());
CREATE TABLE IF NOT EXISTS core.business_memberships(
 id UUID PRIMARY KEY DEFAULT gen_random_uuid(),business_id UUID NOT NULL,user_id UUID NOT NULL,
 role TEXT NOT NULL CHECK(role IN('OWNER','MANAGER','RECEPTIONIST','EMPLOYEE','VIEWER')),
 active BOOLEAN NOT NULL DEFAULT true,created_at TIMESTAMPTZ NOT NULL DEFAULT now(),updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
 UNIQUE(business_id,user_id));
CREATE TABLE IF NOT EXISTS core.platform_admins(
 user_id UUID PRIMARY KEY,active BOOLEAN NOT NULL DEFAULT true,created_at TIMESTAMPTZ NOT NULL DEFAULT now());
CREATE TABLE IF NOT EXISTS core.audit_log(
 id BIGSERIAL PRIMARY KEY,business_id UUID,actor_user_id UUID,actor_type TEXT NOT NULL,
 action TEXT NOT NULL,entity_type TEXT,entity_id TEXT,request_id TEXT,payload JSONB NOT NULL DEFAULT '{}'::jsonb,
 created_at TIMESTAMPTZ NOT NULL DEFAULT now());

CREATE OR REPLACE FUNCTION private.user_role_for_business(p_user UUID,p_business UUID)
RETURNS TEXT LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
 SELECT CASE
  WHEN EXISTS(SELECT 1 FROM core.platform_admins a WHERE a.user_id=p_user AND a.active) THEN 'PLATFORM_ADMIN'
  ELSE (SELECT m.role FROM core.business_memberships m WHERE m.user_id=p_user AND m.business_id=p_business AND m.active LIMIT 1)
 END $$;
REVOKE ALL ON FUNCTION private.user_role_for_business(UUID,UUID) FROM PUBLIC;

CREATE OR REPLACE FUNCTION core.authorize_action_v1(p_user UUID,p_business UUID,p_action TEXT)
RETURNS BOOLEAN LANGUAGE plpgsql STABLE AS $$
DECLARE r text;
BEGIN
 r:=private.user_role_for_business(p_user,p_business);
 IF r='PLATFORM_ADMIN' THEN RETURN true; END IF;
 IF r='OWNER' THEN RETURN true; END IF;
 IF r='MANAGER' THEN RETURN upper(p_action) NOT IN('DELETE_BUSINESS','TRANSFER_OWNERSHIP'); END IF;
 IF r='RECEPTIONIST' THEN RETURN upper(p_action) IN('LIST_APPOINTMENTS','CREATE_APPOINTMENT','CANCEL_APPOINTMENT','RESCHEDULE_APPOINTMENT','GET_CUSTOMER','UPDATE_CUSTOMER','JOIN_WAITLIST'); END IF;
 IF r='EMPLOYEE' THEN RETURN upper(p_action) IN('LIST_MY_APPOINTMENTS','SET_MY_AVAILABILITY','CHECK_IN','COMPLETE_APPOINTMENT'); END IF;
 IF r='VIEWER' THEN RETURN upper(p_action) LIKE 'GET_%' OR upper(p_action) LIKE 'LIST_%'; END IF;
 RETURN false;
END $$;

CREATE OR REPLACE FUNCTION core.execute_control_plane_action_v2(
 p_actor_user_id UUID,p_business_id UUID,p_action TEXT,p_arguments JSONB,p_idempotency_key TEXT,p_execution_ref TEXT
) RETURNS JSONB LANGUAGE plpgsql AS $$
DECLARE a text:=upper(coalesce(p_action,'')); result jsonb;
BEGIN
 IF NOT core.authorize_action_v1(p_actor_user_id,p_business_id,a) THEN
  RETURN jsonb_build_object('ok',false,'code','FORBIDDEN');
 END IF;
 IF nullif(btrim(p_idempotency_key),'') IS NULL THEN RETURN jsonb_build_object('ok',false,'code','IDEMPOTENCY_KEY_REQUIRED'); END IF;

 IF a='SET_MARKETING_CONSENT' THEN
  result:=core.set_marketing_consent_v1(p_business_id,(p_arguments->>'customer_id')::uuid,(p_arguments->>'marketing_opt_in')::boolean,'CONTROL_PLANE');
 ELSIF a='UPSERT_PRODUCT' THEN
  INSERT INTO core.products(id,business_id,sku,name,description,price,currency,stock_status,active,tags,attributes)
  VALUES(coalesce(nullif(p_arguments->>'id','')::uuid,gen_random_uuid()),p_business_id,p_arguments->>'sku',p_arguments->>'name',
    p_arguments->>'description',nullif(p_arguments->>'price','')::numeric,coalesce(p_arguments->>'currency','BRL'),
    coalesce(p_arguments->>'stock_status','UNKNOWN'),coalesce((p_arguments->>'active')::boolean,true),
    coalesce(ARRAY(SELECT jsonb_array_elements_text(p_arguments->'tags')),'{}'::text[]),coalesce(p_arguments->'attributes','{}'::jsonb))
  ON CONFLICT(business_id,sku) DO UPDATE SET name=excluded.name,description=excluded.description,price=excluded.price,
    currency=excluded.currency,stock_status=excluded.stock_status,active=excluded.active,tags=excluded.tags,attributes=excluded.attributes,updated_at=now();
  result:=jsonb_build_object('ok',true,'code','PRODUCT_UPSERTED');
 ELSIF a='CREATE_CAMPAIGN' THEN
  INSERT INTO core.campaigns(business_id,name,status,objective,audience_rules,content,scheduled_at,starts_at,ends_at,created_by)
  VALUES(p_business_id,p_arguments->>'name',coalesce(p_arguments->>'status','DRAFT'),p_arguments->>'objective',
   coalesce(p_arguments->'audience_rules','{}'::jsonb),coalesce(p_arguments->'content','{}'::jsonb),
   nullif(p_arguments->>'scheduled_at','')::timestamptz,nullif(p_arguments->>'starts_at','')::timestamptz,
   nullif(p_arguments->>'ends_at','')::timestamptz,p_actor_user_id)
  RETURNING jsonb_build_object('ok',true,'code','CAMPAIGN_CREATED','campaign_id',id) INTO result;
 ELSE
  result:=jsonb_build_object('ok',false,'code','ACTION_NOT_AVAILABLE_IN_CONTROL_PLANE','action',a);
 END IF;

 INSERT INTO core.audit_log(business_id,actor_user_id,actor_type,action,request_id,payload)
 VALUES(p_business_id,p_actor_user_id,'USER',a,p_execution_ref,jsonb_build_object('arguments',p_arguments,'result',result));
 RETURN result;
END $$;


-- ============================================================
-- SOURCE: 048_runtime_v5_adapters.sql
-- ============================================================

-- 048_runtime_v5_adapters.sql
CREATE OR REPLACE FUNCTION core.queue_outbound_notification_v1(
 p_business_id UUID,p_customer_id UUID,p_notification_type TEXT,p_content JSONB,p_dedupe_key TEXT,p_execution_ref TEXT
) RETURNS JSONB LANGUAGE plpgsql AS $$
DECLARE cc record; bc record; msg jsonb; job_id uuid; text_value text; payload jsonb;
BEGIN
 SELECT * INTO cc FROM core.customer_channels
 WHERE business_id=p_business_id AND customer_id=p_customer_id AND channel_type='WHATSAPP' AND provider='META' AND active=true
 ORDER BY is_primary DESC,updated_at DESC LIMIT 1;
 IF NOT FOUND THEN RETURN jsonb_build_object('ok',false,'code','CUSTOMER_CHANNEL_NOT_FOUND'); END IF;
 SELECT * INTO bc FROM core.business_channels WHERE business_id=p_business_id AND channel_type='WHATSAPP' AND provider='META' AND status='ACTIVE'
 ORDER BY updated_at DESC LIMIT 1;
 IF NOT FOUND THEN RETURN jsonb_build_object('ok',false,'code','BUSINESS_CHANNEL_NOT_FOUND'); END IF;
 text_value:=coalesce(p_content->>'text',
  CASE upper(p_notification_type)
   WHEN 'APPOINTMENT_REMINDER' THEN 'Lembrete: você tem um horário marcado em breve.'
   ELSE 'Temos uma atualização para você.' END);
 payload:=jsonb_build_object('messaging_product','whatsapp','recipient_type','individual','to',cc.external_user_id,'type','text',
  'text',jsonb_build_object('body',text_value));
 job_id:=core.enqueue_integration_job_v1(p_business_id,'WHATSAPP_OUTBOUND','SEND',
  jsonb_build_object('phone_number_id',bc.external_channel_id,'recipient',cc.external_user_id,'meta_payload',payload,
    'graph_api_version','v26.0','notification_type',p_notification_type),
  p_dedupe_key,'CUSTOMER',p_customer_id,100,8,now(),p_execution_ref,NULL);
 RETURN jsonb_build_object('ok',true,'code','OUTBOUND_QUEUED','job_id',job_id);
END $$;

CREATE OR REPLACE FUNCTION core.claim_outbound_delivery_batch(p_limit INTEGER,p_worker_ref TEXT)
RETURNS TABLE(job JSONB) LANGUAGE sql AS $$
SELECT jsonb_build_object('job_id',j.id,'business_id',j.business_id,'phone_number_id',j.payload->>'phone_number_id',
 'recipient',j.payload->>'recipient','graph_api_version',coalesce(j.payload->>'graph_api_version','v26.0'),
 'meta_payload',j.payload->'meta_payload')
FROM core.claim_integration_jobs_v1('WHATSAPP_OUTBOUND',p_limit,p_worker_ref,120) q(job)
JOIN LATERAL jsonb_to_record(q.job) AS j0(id uuid) ON true
JOIN core.integration_jobs j ON j.id=j0.id $$;
CREATE OR REPLACE FUNCTION core.complete_outbound_delivery(p_job_id UUID,p_external_message_id TEXT,p_provider_response JSONB)
RETURNS JSONB LANGUAGE sql AS $$ SELECT core.complete_integration_job_v1(p_job_id,p_provider_response||jsonb_build_object('external_message_id',p_external_message_id)) $$;
CREATE OR REPLACE FUNCTION core.fail_outbound_delivery(p_job_id UUID,p_error TEXT,p_provider_response JSONB)
RETURNS JSONB LANGUAGE sql AS $$ SELECT core.fail_integration_job_v1(p_job_id,p_error,p_provider_response) $$;

CREATE OR REPLACE FUNCTION core.claim_calendar_sync_batch(p_limit INTEGER,p_worker_ref TEXT)
RETURNS TABLE(job JSONB) LANGUAGE sql AS $$
SELECT j.payload||jsonb_build_object('job_id',j.id,'business_id',j.business_id,'operation',j.operation)
FROM core.claim_integration_jobs_v1('CALENDAR_SYNC',p_limit,p_worker_ref,180) q(job)
JOIN LATERAL jsonb_to_record(q.job) AS j0(id uuid) ON true
JOIN core.integration_jobs j ON j.id=j0.id $$;
CREATE OR REPLACE FUNCTION core.complete_calendar_sync_job(p_job_id UUID,p_external_event_id TEXT,p_provider_response JSONB)
RETURNS JSONB LANGUAGE sql AS $$ SELECT core.complete_integration_job_v1(p_job_id,p_provider_response||jsonb_build_object('external_event_id',p_external_event_id)) $$;
CREATE OR REPLACE FUNCTION core.fail_calendar_sync_job(p_job_id UUID,p_error TEXT,p_provider_response JSONB)
RETURNS JSONB LANGUAGE sql AS $$ SELECT core.fail_integration_job_v1(p_job_id,p_error,p_provider_response) $$;

CREATE OR REPLACE FUNCTION core.ingest_whatsapp_event_v1(
 p_external_channel_id TEXT,p_channel_type TEXT,p_provider TEXT,p_external_user_id TEXT,p_profile_name TEXT,
 p_idempotency_key TEXT,p_external_message_id TEXT,p_message_type TEXT,p_interaction JSONB,p_media JSONB,p_envelope JSONB,
 p_provider_timestamp TIMESTAMPTZ,p_execution_ref TEXT
) RETURNS JSONB LANGUAGE plpgsql AS $$
DECLARE bc record; prep jsonb; message_id uuid; business_id uuid; context jsonb; asset_id uuid; payload jsonb;
BEGIN
 SELECT * INTO bc FROM core.business_channels WHERE provider=p_provider AND external_channel_id=p_external_channel_id AND status='ACTIVE' LIMIT 1;
 IF NOT FOUND THEN RETURN jsonb_build_object('ok',false,'code','BUSINESS_CHANNEL_NOT_FOUND'); END IF;
 business_id:=bc.business_id;
 prep:=core.prepare_assistant_turn(
   (SELECT code FROM core.businesses WHERE id=business_id),p_channel_type,p_provider,p_external_user_id,
   p_idempotency_key,p_external_message_id,p_message_type,p_envelope->>'text',
   coalesce(p_envelope->'raw_payload','{}'::jsonb),p_provider_timestamp,20);
 IF coalesce((prep#>>'{turn,should_process}')::boolean,false) IS NOT TRUE THEN
   RETURN jsonb_build_object('ok',true,'code','DUPLICATE_OR_IGNORED','context',prep);
 END IF;
 message_id:=(prep#>>'{turn,message_id}')::uuid;
 context:=prep;
 payload:=jsonb_build_object('message_id',message_id,'message',jsonb_build_object('type',p_message_type,'text',p_envelope->>'text',
   'interaction',coalesce(p_interaction,'{}'::jsonb)),'context',context);

 IF lower(p_message_type) IN('audio','image','document','video','sticker') AND nullif(p_media->>'id','') IS NOT NULL THEN
   INSERT INTO core.media_assets(business_id,message_id,media_id,mime_type,filename,caption)
   VALUES(business_id,message_id,p_media->>'id',p_media->>'mime_type',p_media->>'filename',p_media->>'caption')
   ON CONFLICT(business_id,provider,media_id) DO UPDATE SET updated_at=now()
   RETURNING id INTO asset_id;
   PERFORM core.enqueue_integration_job_v1(business_id,'MEDIA_PROCESS','PROCESS',
      jsonb_build_object('media_asset_id',asset_id,'media_id',p_media->>'id','media_type',p_message_type,'mime_type',p_media->>'mime_type',
       'filename',p_media->>'filename','caption',p_media->>'caption','message_id',message_id,'conversation_payload',payload),
      'MEDIA:'||p_provider||':'||(p_media->>'id'),'MESSAGE',message_id,40,6,now(),p_execution_ref,NULL);
   RETURN jsonb_build_object('ok',true,'code','MEDIA_DEFERRED','message_id',message_id,'media_asset_id',asset_id);
 ELSE
   PERFORM core.enqueue_integration_job_v1(business_id,'CONVERSATION_TURN','PROCESS',payload,
     'CONVERSATION:'||message_id,'MESSAGE',message_id,50,5,now(),p_execution_ref,NULL);
   RETURN jsonb_build_object('ok',true,'code','CONVERSATION_QUEUED','message_id',message_id);
 END IF;
END $$;

CREATE OR REPLACE FUNCTION core.claim_conversation_turn_batch(p_limit INTEGER,p_worker_ref TEXT)
RETURNS TABLE(job JSONB) LANGUAGE sql AS $$
SELECT jsonb_build_object('job_id',j.id,'business_id',j.business_id)
FROM core.claim_integration_jobs_v1('CONVERSATION_TURN',p_limit,p_worker_ref,300) q(job)
JOIN LATERAL jsonb_to_record(q.job) AS j0(id uuid) ON true JOIN core.integration_jobs j ON j.id=j0.id $$;

CREATE OR REPLACE FUNCTION core.prepare_conversation_job_v1(p_job_id UUID,p_execution_ref TEXT)
RETURNS JSONB LANGUAGE plpgsql AS $$
DECLARE j core.integration_jobs%rowtype; payload jsonb; b uuid; q text;
BEGIN
 SELECT * INTO j FROM core.integration_jobs WHERE id=p_job_id;
 IF NOT FOUND THEN RETURN jsonb_build_object('ok',false,'code','JOB_NOT_FOUND'); END IF;
 payload:=j.payload;b:=j.business_id;q:=coalesce(payload#>>'{message,text}',payload#>>'{media_context,summary}','');
 payload:=jsonb_set(payload,'{context,catalog_context}',core.get_catalog_context_v1(b),true);
 payload:=jsonb_set(payload,'{context,knowledge_context}',core.search_business_knowledge_v1(b,q,8),true);
 payload:=jsonb_set(payload,'{context,promotion_context}',
   coalesce((SELECT jsonb_agg(jsonb_build_object('campaign_id',id,'name',name,'content',content,'ends_at',ends_at))
     FROM core.campaigns WHERE business_id=b AND status='RUNNING' AND (ends_at IS NULL OR ends_at>now())),'[]'::jsonb),true);
 RETURN payload||jsonb_build_object('job_id',j.id,'ok',true);
END $$;

CREATE OR REPLACE FUNCTION core.execute_assistant_action_v5(
 p_business_id UUID,p_conversation_id UUID,p_customer_id UUID,p_channel_type TEXT,p_provider TEXT,p_action TEXT,p_arguments JSONB,p_execution_ref TEXT
) RETURNS JSONB LANGUAGE plpgsql AS $$
DECLARE r jsonb; c jsonb; src jsonb; rep jsonb;
BEGIN
 IF p_action='UPDATE_MARKETING_PREFERENCE' THEN
  RETURN core.set_marketing_consent_v1(p_business_id,p_customer_id,coalesce((p_arguments->>'marketing_opt_in')::boolean,false),'ASSISTANT');
 END IF;
 IF p_action='LEAVE_WAITLIST' THEN
  BEGIN
   EXECUTE 'SELECT core.leave_waitlist($1,$2,$3)' INTO r USING p_business_id,p_customer_id,nullif(p_arguments->>'waitlist_id','')::uuid;
   RETURN r;
  EXCEPTION WHEN undefined_function THEN RETURN jsonb_build_object('ok',false,'code','LEAVE_WAITLIST_NOT_SUPPORTED'); END;
 END IF;
 r:=core.execute_assistant_action_v3(p_business_id,p_conversation_id,p_customer_id,p_channel_type,p_provider,p_action,p_arguments);
 IF coalesce((r->>'ok')::boolean,false) IS TRUE THEN
   c:=r->'calendar_sync';
   IF coalesce((c->>'required')::boolean,false) THEN
     PERFORM core.enqueue_integration_job_v1(p_business_id,'CALENDAR_SYNC',coalesce(c->>'operation','CREATE'),
       c||jsonb_build_object('appointment_id',c->>'appointment_id'),
       'CAL:'||coalesce(c->>'operation','CREATE')||':'||(c->>'appointment_id'),'APPOINTMENT',nullif(c->>'appointment_id','')::uuid,60,8,now(),p_execution_ref,NULL);
   END IF;
   IF coalesce((r#>>'{calendar_reschedule,required}')::boolean,false) THEN
     src:=r#>'{calendar_reschedule,source}';rep:=r#>'{calendar_reschedule,replacement}';
     IF coalesce((src->>'delete_required')::boolean,false) THEN
       PERFORM core.enqueue_integration_job_v1(p_business_id,'CALENDAR_SYNC','DELETE',src,
        'CAL:DELETE:'||(src->>'appointment_id'),'APPOINTMENT',(src->>'appointment_id')::uuid,50,8,now(),p_execution_ref,NULL);
     END IF;
     IF coalesce((rep->>'create_required')::boolean,false) THEN
       PERFORM core.enqueue_integration_job_v1(p_business_id,'CALENDAR_SYNC','CREATE',rep,
        'CAL:CREATE:'||(rep->>'appointment_id'),'APPOINTMENT',(rep->>'appointment_id')::uuid,60,8,now(),p_execution_ref,NULL);
     END IF;
   END IF;
 END IF;
 RETURN r;
END $$;

CREATE OR REPLACE FUNCTION core.finalize_conversation_job_v1(
 p_job_id UUID,p_command JSONB,p_execution JSONB,p_response JSONB,p_execution_ref TEXT
) RETURNS JSONB LANGUAGE plpgsql AS $$
DECLARE j core.integration_jobs%rowtype; p jsonb; ctx jsonb; f jsonb; q jsonb;
BEGIN
 SELECT * INTO j FROM core.integration_jobs WHERE id=p_job_id FOR UPDATE;
 IF NOT FOUND THEN RETURN jsonb_build_object('ok',false,'code','JOB_NOT_FOUND'); END IF;
 p:=j.payload;ctx:=p->'context';
 f:=core.finalize_assistant_turn(
  (ctx#>>'{business,id}')::uuid,(ctx#>>'{conversation,id}')::uuid,(ctx#>>'{customer,id}')::uuid,
  (ctx#>>'{customer,channel_id}')::uuid,ctx#>>'{channel,channel_type}',ctx#>>'{channel,provider}',
  (ctx#>>'{turn,message_id}')::uuid,p_command->>'intent',coalesce((p_command->>'confidence')::numeric,0),
  p_command->>'kind',coalesce(p_command->>'route',CASE WHEN p_command->>'kind'='BUSINESS_ACTION' THEN 'CORE' ELSE 'DIRECT_RESPONSE' END),
  p_command->>'action',p_response->>'text',p_response->>'response_type',coalesce(p_response->>'source','RESPONSE_ENGINE'),
  coalesce((p_response->>'should_send')::boolean,true));
 IF coalesce((f->>'should_send')::boolean,false) THEN
   q:=core.queue_outbound_notification_v1((ctx#>>'{business,id}')::uuid,(ctx#>>'{customer,id}')::uuid,'CONVERSATION_RESPONSE',
      jsonb_build_object('text',p_response->>'text'),
      'TURN:'||(ctx#>>'{turn,message_id}'),p_execution_ref);
 END IF;
 PERFORM core.complete_integration_job_v1(p_job_id,jsonb_build_object('finalization',f,'execution',p_execution));
 RETURN jsonb_build_object('ok',true,'code','TURN_FINALIZED','finalization',f,'delivery',q);
END $$;


-- ============================================================
-- SOURCE: 049_observability.sql
-- ============================================================

-- 049_observability.sql
CREATE TABLE IF NOT EXISTS core.automation_incidents(
 id BIGSERIAL PRIMARY KEY,business_id UUID,severity TEXT NOT NULL DEFAULT 'ERROR',
 workflow TEXT,execution_id TEXT,node TEXT,error_code TEXT,error_message TEXT,correlation_id TEXT,
 context JSONB NOT NULL DEFAULT '{}'::jsonb,status TEXT NOT NULL DEFAULT 'OPEN' CHECK(status IN('OPEN','ACKNOWLEDGED','RESOLVED')),
 created_at TIMESTAMPTZ NOT NULL DEFAULT now(),resolved_at TIMESTAMPTZ);
CREATE INDEX IF NOT EXISTS idx_incidents_open ON core.automation_incidents(status,severity,created_at DESC);

CREATE OR REPLACE FUNCTION core.record_automation_incident_v1(
 p_business_id UUID,p_severity TEXT,p_workflow TEXT,p_execution_id TEXT,p_node TEXT,p_error_code TEXT,p_error_message TEXT,p_context JSONB
) RETURNS JSONB LANGUAGE plpgsql AS $$
DECLARE v bigint;
BEGIN
 INSERT INTO core.automation_incidents(business_id,severity,workflow,execution_id,node,error_code,error_message,context)
 VALUES(p_business_id,coalesce(p_severity,'ERROR'),p_workflow,p_execution_id,p_node,p_error_code,left(p_error_message,4000),coalesce(p_context,'{}'::jsonb))
 RETURNING id INTO v;
 RETURN jsonb_build_object('ok',true,'incident_id',v);
END $$;


-- ============================================================
-- SOURCE: 050_security_rls.sql
-- ============================================================

-- 050_security_rls.sql
-- New UI-facing tables use Supabase Auth/RLS. Core operational tables remain server-side.
CREATE TABLE IF NOT EXISTS public.ml_user_businesses(
 business_id UUID NOT NULL,user_id UUID NOT NULL,role TEXT NOT NULL,active BOOLEAN NOT NULL DEFAULT true,
 PRIMARY KEY(business_id,user_id));
ALTER TABLE public.ml_user_businesses ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.ml_user_businesses FROM anon;
GRANT SELECT ON public.ml_user_businesses TO authenticated;
DROP POLICY IF EXISTS ml_user_businesses_self ON public.ml_user_businesses;
CREATE POLICY ml_user_businesses_self ON public.ml_user_businesses FOR SELECT TO authenticated
USING ((SELECT auth.uid())=user_id);

CREATE OR REPLACE FUNCTION public.ml_sync_my_memberships()
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE u uuid:=(SELECT auth.uid());
BEGIN
 IF u IS NULL THEN RAISE EXCEPTION 'UNAUTHENTICATED'; END IF;
 INSERT INTO public.ml_user_businesses(business_id,user_id,role,active)
 SELECT m.business_id,m.user_id,m.role,m.active FROM core.business_memberships m WHERE m.user_id=u
 ON CONFLICT(business_id,user_id) DO UPDATE SET role=excluded.role,active=excluded.active;
 RETURN jsonb_build_object('ok',true);
END $$;
REVOKE ALL ON FUNCTION public.ml_sync_my_memberships() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.ml_sync_my_memberships() TO authenticated;

-- The service_role remains server-side; do not expose core schema to anon.


-- ============================================================
-- SOURCE: 051_whatsapp_calendar_hardening.sql
-- ============================================================
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


-- ============================================================
-- SOURCE: 052_engagement_automation_v3.sql
-- ============================================================
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


-- ============================================================
-- SOURCE: 053_waitlist_engine_v2.sql
-- ============================================================
-- 053_waitlist_engine_v2.sql
-- Canonical, tenant-safe, idempotent waitlist engine integrated with slot offers and outbox.

CREATE TABLE IF NOT EXISTS core.waitlist_subscriptions_v2 (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    business_id UUID NOT NULL REFERENCES core.businesses(id) ON DELETE CASCADE,
    customer_id UUID NOT NULL,
    conversation_id UUID NOT NULL,
    service_id UUID NOT NULL,
    professional_id UUID,
    date_from DATE NOT NULL,
    date_until DATE NOT NULL,
    time_from TIME,
    time_until TIME,
    status TEXT NOT NULL DEFAULT 'WAITING'
        CHECK (status IN ('WAITING','OFFERED','BOOKED','CANCELLED','EXPIRED')),
    last_slot_offer_id UUID,
    offer_expires_at TIMESTAMPTZ,
    last_checked_at TIMESTAMPTZ,
    source TEXT NOT NULL DEFAULT 'ASSISTANT',
    metadata JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT fk_waitlist_v2_customer
      FOREIGN KEY (business_id,customer_id) REFERENCES core.customers(business_id,id) ON DELETE CASCADE,
    CONSTRAINT fk_waitlist_v2_conversation
      FOREIGN KEY (business_id,conversation_id) REFERENCES core.conversations(business_id,id) ON DELETE CASCADE,
    CONSTRAINT fk_waitlist_v2_service
      FOREIGN KEY (business_id,service_id) REFERENCES core.services(business_id,id) ON DELETE RESTRICT,
    CONSTRAINT chk_waitlist_v2_dates CHECK (date_from <= date_until),
    CONSTRAINT chk_waitlist_v2_times CHECK (time_from IS NULL OR time_until IS NULL OR time_from < time_until)
);

CREATE INDEX IF NOT EXISTS idx_waitlist_v2_claim
ON core.waitlist_subscriptions_v2(status,date_from,date_until,created_at)
WHERE status IN ('WAITING','OFFERED');

CREATE UNIQUE INDEX IF NOT EXISTS uq_waitlist_v2_active_request
ON core.waitlist_subscriptions_v2(
  business_id,customer_id,service_id,
  coalesce(professional_id,'00000000-0000-0000-0000-000000000000'::uuid),
  date_from,date_until,
  coalesce(time_from,'00:00'::time),coalesce(time_until,'23:59:59'::time)
)
WHERE status IN ('WAITING','OFFERED');

CREATE OR REPLACE FUNCTION core.join_waitlist_v2(
    p_business_id UUID,
    p_conversation_id UUID,
    p_customer_id UUID,
    p_service_id UUID,
    p_professional_id UUID DEFAULT NULL,
    p_date_from DATE DEFAULT NULL,
    p_date_until DATE DEFAULT NULL,
    p_time_from TIME DEFAULT NULL,
    p_time_until TIME DEFAULT NULL,
    p_source TEXT DEFAULT 'ASSISTANT'
)
RETURNS JSONB
LANGUAGE plpgsql
VOLATILE
AS $function$
DECLARE
    v_business core.businesses%ROWTYPE;
    v_settings core.business_settings%ROWTYPE;
    v_today DATE;
    v_from DATE;
    v_until DATE;
    v_existing core.waitlist_subscriptions_v2%ROWTYPE;
    v_row core.waitlist_subscriptions_v2%ROWTYPE;
BEGIN
    SELECT * INTO v_business FROM core.businesses
    WHERE id=p_business_id AND status='ACTIVE' LIMIT 1;
    IF NOT FOUND THEN RETURN jsonb_build_object('ok',false,'code','BUSINESS_NOT_FOUND'); END IF;

    SELECT * INTO v_settings FROM core.business_settings WHERE business_id=p_business_id LIMIT 1;
    IF NOT FOUND OR coalesce(v_settings.waitlist_enabled,false) IS NOT TRUE THEN
        RETURN jsonb_build_object('ok',false,'code','WAITLIST_DISABLED');
    END IF;

    IF NOT EXISTS (
      SELECT 1 FROM core.conversations c
      WHERE c.business_id=p_business_id AND c.id=p_conversation_id
        AND c.customer_id=p_customer_id AND c.status='OPEN'
    ) THEN
      RETURN jsonb_build_object('ok',false,'code','INVALID_CONVERSATION_CONTEXT');
    END IF;

    IF p_service_id IS NULL OR NOT EXISTS (
      SELECT 1 FROM core.services s
      WHERE s.business_id=p_business_id AND s.id=p_service_id AND s.active=true AND s.online_booking_enabled=true
    ) THEN
      RETURN jsonb_build_object('ok',false,'code','SERVICE_NOT_AVAILABLE');
    END IF;

    IF p_professional_id IS NOT NULL AND NOT EXISTS (
      SELECT 1 FROM core.professionals p
      WHERE p.business_id=p_business_id AND p.id=p_professional_id AND p.active=true AND p.online_booking_enabled=true
    ) THEN
      RETURN jsonb_build_object('ok',false,'code','PROFESSIONAL_NOT_AVAILABLE');
    END IF;

    v_today := (now() AT TIME ZONE v_business.timezone)::date;
    v_from := greatest(coalesce(p_date_from,v_today),v_today);
    v_until := least(
      coalesce(p_date_until,v_from + 7),
      v_today + greatest(coalesce(v_settings.maximum_booking_horizon_days,60),1)
    );

    IF v_until < v_from THEN RETURN jsonb_build_object('ok',false,'code','INVALID_WAITLIST_DATE_RANGE'); END IF;
    IF p_time_from IS NOT NULL AND p_time_until IS NOT NULL AND p_time_from >= p_time_until THEN
      RETURN jsonb_build_object('ok',false,'code','INVALID_WAITLIST_TIME_RANGE');
    END IF;

    SELECT * INTO v_existing
    FROM core.waitlist_subscriptions_v2 w
    WHERE w.business_id=p_business_id AND w.customer_id=p_customer_id
      AND w.service_id=p_service_id
      AND w.professional_id IS NOT DISTINCT FROM p_professional_id
      AND w.date_from=v_from AND w.date_until=v_until
      AND w.time_from IS NOT DISTINCT FROM p_time_from
      AND w.time_until IS NOT DISTINCT FROM p_time_until
      AND w.status IN ('WAITING','OFFERED')
    ORDER BY w.created_at DESC LIMIT 1 FOR UPDATE;

    IF FOUND THEN
      RETURN jsonb_build_object('ok',true,'code','WAITLIST_ALREADY_ACTIVE','waitlist_id',v_existing.id,'status',v_existing.status);
    END IF;

    BEGIN
      INSERT INTO core.waitlist_subscriptions_v2(
        business_id,customer_id,conversation_id,service_id,professional_id,date_from,date_until,time_from,time_until,source
      ) VALUES (
        p_business_id,p_customer_id,p_conversation_id,p_service_id,p_professional_id,v_from,v_until,p_time_from,p_time_until,coalesce(p_source,'ASSISTANT')
      ) RETURNING * INTO v_row;
    EXCEPTION WHEN unique_violation THEN
      SELECT * INTO v_row FROM core.waitlist_subscriptions_v2 w
      WHERE w.business_id=p_business_id AND w.customer_id=p_customer_id AND w.service_id=p_service_id
        AND w.professional_id IS NOT DISTINCT FROM p_professional_id
        AND w.date_from=v_from AND w.date_until=v_until
        AND w.time_from IS NOT DISTINCT FROM p_time_from AND w.time_until IS NOT DISTINCT FROM p_time_until
        AND w.status IN ('WAITING','OFFERED') ORDER BY w.created_at DESC LIMIT 1;
    END;

    UPDATE core.conversations
    SET current_intent='JOIN_WAITLIST',pending_action=NULL,
        context=jsonb_set(coalesce(context,'{}'::jsonb),'{waitlist}',jsonb_build_object('waitlist_id',v_row.id),true)
    WHERE business_id=p_business_id AND id=p_conversation_id;

    RETURN jsonb_build_object(
      'ok',true,'code','WAITLIST_JOINED','result_type','WAITLIST_CONFIRMATION',
      'waitlist',jsonb_build_object('waitlist_id',v_row.id,'status',v_row.status,'date_from',v_row.date_from,'date_until',v_row.date_until)
    );
END;
$function$;

CREATE OR REPLACE FUNCTION core.leave_waitlist_v2(
    p_business_id UUID,p_customer_id UUID,p_waitlist_id UUID DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
VOLATILE
AS $function$
DECLARE v_count INTEGER;
BEGIN
    UPDATE core.waitlist_subscriptions_v2
    SET status='CANCELLED',updated_at=now()
    WHERE business_id=p_business_id AND customer_id=p_customer_id
      AND status IN ('WAITING','OFFERED')
      AND (p_waitlist_id IS NULL OR id=p_waitlist_id);
    GET DIAGNOSTICS v_count=ROW_COUNT;
    RETURN jsonb_build_object('ok',true,'code',CASE WHEN v_count>0 THEN 'WAITLIST_LEFT' ELSE 'WAITLIST_NOT_ACTIVE' END,'cancelled',v_count);
END;
$function$;

CREATE OR REPLACE FUNCTION core.process_waitlist_automation_v2(p_limit INTEGER,p_execution_ref TEXT)
RETURNS JSONB
LANGUAGE plpgsql
VOLATILE
AS $function$
DECLARE
    r RECORD;
    v_offer JSONB;
    v_count INTEGER:=0;
    v_offered INTEGER:=0;
    v_expired INTEGER:=0;
    v_result JSONB;
    v_text TEXT;
    v_limit INTEGER;
    v_ttl INTEGER;
BEGIN
    UPDATE core.waitlist_subscriptions_v2
    SET status='WAITING',last_slot_offer_id=NULL,offer_expires_at=NULL,updated_at=now()
    WHERE status='OFFERED' AND offer_expires_at IS NOT NULL AND offer_expires_at<=now();

    UPDATE core.waitlist_subscriptions_v2 w
    SET status='EXPIRED',updated_at=now()
    FROM core.businesses b
    WHERE w.business_id=b.id AND w.status IN ('WAITING','OFFERED')
      AND w.date_until < (now() AT TIME ZONE b.timezone)::date;
    GET DIAGNOSTICS v_expired=ROW_COUNT;

    FOR r IN
      SELECT w.*,bs.max_slots_per_offer,bs.waitlist_offer_ttl_minutes,b.timezone
      FROM core.waitlist_subscriptions_v2 w
      JOIN core.business_settings bs ON bs.business_id=w.business_id AND bs.waitlist_enabled=true
      JOIN core.businesses b ON b.id=w.business_id
      JOIN core.conversations c ON c.business_id=w.business_id AND c.id=w.conversation_id AND c.status='OPEN'
      WHERE w.status='WAITING'
        AND w.date_until >= (now() AT TIME ZONE b.timezone)::date
        AND (c.pending_action IS NULL OR c.pending_action IN ('JOIN_WAITLIST','WAITLIST'))
      ORDER BY w.created_at
      LIMIT greatest(1,least(coalesce(p_limit,250),1000))
      FOR UPDATE OF w SKIP LOCKED
    LOOP
      v_limit:=greatest(1,least(coalesce(r.max_slots_per_offer,5),10));
      v_ttl:=greatest(1,least(coalesce(r.waitlist_offer_ttl_minutes,10),120));
      UPDATE core.waitlist_subscriptions_v2 SET last_checked_at=now(),updated_at=now() WHERE id=r.id;

      v_offer:=core.create_slot_offer(
        r.business_id,r.conversation_id,ARRAY[r.service_id],r.date_from,r.date_until,
        r.professional_id,r.time_from,r.time_until,v_limit,v_ttl
      );

      IF coalesce((v_offer->>'ok')::boolean,false) AND coalesce((v_offer->>'count')::integer,0)>0 THEN
        v_text:='Abriu um horário que combina com o que você pediu na lista de espera. Escolha uma opção abaixo:';
        v_result:=core.queue_outbound_notification_v3(
          r.business_id,r.customer_id,'WAITLIST_SLOT_OFFER',
          jsonb_build_object('text',v_text,'metadata',jsonb_build_object('waitlist_id',r.id)),
          'WAITLIST_OFFER:'||r.id||':'||(v_offer->>'slot_offer_id'),p_execution_ref,
          jsonb_build_object('result',v_offer),'SLOT_OPTIONS'
        );
        IF coalesce((v_result->>'ok')::boolean,false) THEN
          UPDATE core.waitlist_subscriptions_v2
          SET status='OFFERED',last_slot_offer_id=(v_offer->>'slot_offer_id')::uuid,
              offer_expires_at=nullif(v_offer->>'expires_at','')::timestamptz,updated_at=now()
          WHERE id=r.id;
          v_offered:=v_offered+1;
        END IF;
      END IF;
      v_count:=v_count+1;
    END LOOP;

    RETURN jsonb_build_object('ok',true,'checked',v_count,'offered',v_offered,'expired',v_expired);
END;
$function$;

CREATE OR REPLACE FUNCTION core.process_waitlist_automation_v1(p_limit INTEGER,p_execution_ref TEXT)
RETURNS JSONB LANGUAGE sql VOLATILE AS $function$
SELECT core.process_waitlist_automation_v2(p_limit,p_execution_ref);
$function$;

CREATE OR REPLACE FUNCTION core.mark_waitlist_booked_from_offer_v1(
  p_business_id UUID,p_customer_id UUID,p_slot_offer_id UUID,p_appointment_id UUID
)
RETURNS JSONB LANGUAGE plpgsql VOLATILE AS $function$
DECLARE v_count INTEGER;
BEGIN
 UPDATE core.waitlist_subscriptions_v2
 SET status='BOOKED',metadata=metadata||jsonb_build_object('appointment_id',p_appointment_id),updated_at=now()
 WHERE business_id=p_business_id AND customer_id=p_customer_id
   AND last_slot_offer_id=p_slot_offer_id AND status='OFFERED';
 GET DIAGNOSTICS v_count=ROW_COUNT;
 RETURN jsonb_build_object('ok',true,'updated',v_count);
END;
$function$;


-- ============================================================
-- SOURCE: 054_runtime_final.sql
-- ============================================================
-- 054_runtime_final.sql
-- Final assistant dispatcher/finalizer. All external side effects become durable jobs.

CREATE OR REPLACE FUNCTION core.enqueue_prepared_cancellation_outbound_v1(
    p_business_id UUID,p_appointment_id UUID,p_execution_ref TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
VOLATILE
AS $function$
DECLARE
    v_out JSONB;
    v_job UUID;
    v_customer_id UUID;
    v_settings JSONB;
    v_template_name TEXT;
    v_template_language TEXT;
    v_content JSONB;
BEGIN
    v_out := core.prepare_appointment_cancellation_outbound(p_business_id,p_appointment_id);
    IF coalesce((v_out->>'ok')::boolean,false) IS NOT TRUE THEN RETURN v_out; END IF;

    IF coalesce((v_out->>'should_send')::boolean,false) THEN
        v_job := core.enqueue_integration_job_v1(
          p_business_id,'WHATSAPP_OUTBOUND','SEND',
          jsonb_build_object(
            'internal_message_id',v_out->>'internal_message_id',
            'phone_number_id',v_out->>'phone_number_id',
            'recipient',v_out->>'recipient',
            'graph_api_version','v26.0',
            'meta_payload',v_out->'meta_payload',
            'notification_type','APPOINTMENT_CANCELLED'
          ),
          'CANCEL_NOTIFY:'||p_appointment_id,'APPOINTMENT',p_appointment_id,70,8,now(),p_execution_ref,NULL
        );
        RETURN v_out || jsonb_build_object('job_id',v_job,'queued',true);
    END IF;

    -- Outside the 24h free-form window: use a configured utility template if available.
    IF v_out->>'code'='WHATSAPP_TEMPLATE_REQUIRED' THEN
        SELECT a.customer_id INTO v_customer_id FROM core.appointments a
        WHERE a.business_id=p_business_id AND a.id=p_appointment_id;
        SELECT coalesce(bs.extra_settings,'{}'::jsonb) INTO v_settings
        FROM core.business_settings bs WHERE bs.business_id=p_business_id;
        v_template_name:=nullif(v_settings#>>'{whatsapp_templates,appointment_cancelled,name}','');
        v_template_language:=coalesce(nullif(v_settings#>>'{whatsapp_templates,appointment_cancelled,language}',''),'pt_BR');
        IF v_template_name IS NULL THEN
          RETURN v_out || jsonb_build_object('queued',false,'configuration_required','appointment_cancelled template');
        END IF;
        v_content:=jsonb_build_object(
          'text','Seu agendamento foi cancelado. Abra a conversa para ver os detalhes ou procurar outro horário.',
          'template_name',v_template_name,
          'template_language',v_template_language,
          'template_components',coalesce(v_settings#>'{whatsapp_templates,appointment_cancelled,components}','[]'::jsonb),
          'metadata',jsonb_build_object('appointment_id',p_appointment_id)
        );
        RETURN core.queue_outbound_notification_v3(
          p_business_id,v_customer_id,'APPOINTMENT_CANCELLED',v_content,
          'CANCEL_TEMPLATE:'||p_appointment_id,p_execution_ref,'{}'::jsonb,'INFORMATION'
        );
    END IF;

    RETURN v_out || jsonb_build_object('queued',false);
END;
$function$;

CREATE OR REPLACE FUNCTION core.execute_assistant_action_final(
    p_business_id UUID,
    p_conversation_id UUID,
    p_customer_id UUID,
    p_channel_type TEXT,
    p_provider TEXT,
    p_action TEXT,
    p_arguments JSONB,
    p_execution_ref TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
VOLATILE
AS $function$
DECLARE
    v_action TEXT:=upper(coalesce(p_action,'NONE'));
    v_result JSONB;
    v_cal JSONB;
    v_src JSONB;
    v_rep JSONB;
    v_appt UUID;
    v_offer UUID;
BEGIN
    IF v_action='UPDATE_MARKETING_PREFERENCE' THEN
      RETURN core.set_marketing_consent_v2(
        p_business_id,p_customer_id,coalesce((p_arguments->>'marketing_opt_in')::boolean,false),'ASSISTANT'
      );
    END IF;

    IF v_action='JOIN_WAITLIST' THEN
      BEGIN
        RETURN core.join_waitlist_v2(
          p_business_id,p_conversation_id,p_customer_id,
          nullif(p_arguments->>'service_id','')::uuid,
          nullif(p_arguments->>'professional_id','')::uuid,
          nullif(p_arguments->>'date','')::date,
          coalesce(nullif(p_arguments->>'date_until','')::date,nullif(p_arguments->>'date','')::date),
          nullif(p_arguments->>'time_from','')::time,
          nullif(p_arguments->>'time_until','')::time,
          'ASSISTANT'
        );
      EXCEPTION WHEN invalid_text_representation THEN
        RETURN jsonb_build_object('ok',false,'code','INVALID_WAITLIST_ARGUMENT');
      END;
    END IF;

    IF v_action='LEAVE_WAITLIST' THEN
      BEGIN
        RETURN core.leave_waitlist_v2(p_business_id,p_customer_id,nullif(p_arguments->>'waitlist_id','')::uuid);
      EXCEPTION WHEN invalid_text_representation THEN
        RETURN jsonb_build_object('ok',false,'code','INVALID_WAITLIST_ID');
      END;
    END IF;

    v_result:=core.execute_assistant_action_v3(
      p_business_id,p_conversation_id,p_customer_id,p_channel_type,p_provider,v_action,coalesce(p_arguments,'{}'::jsonb)
    );

    IF coalesce((v_result->>'ok')::boolean,false) IS NOT TRUE THEN RETURN v_result; END IF;

    -- Simple Calendar operation.
    v_cal:=v_result->'calendar_sync';
    IF coalesce((v_cal->>'required')::boolean,false) THEN
      BEGIN
        PERFORM core.enqueue_calendar_sync_job_v2(
          p_business_id,(v_cal->>'appointment_id')::uuid,v_cal->>'operation',p_execution_ref,NULL
        );
      EXCEPTION WHEN OTHERS THEN
        PERFORM core.record_automation_incident_v1(
          p_business_id,'ERROR','CORE_RUNTIME',p_execution_ref,'CALENDAR_ENQUEUE','CALENDAR_ENQUEUE_FAILED',SQLERRM,
          jsonb_build_object('calendar_sync',v_cal)
        );
      END;
    END IF;

    -- Reschedule is represented as two independent, durable side effects.
    IF coalesce((v_result#>>'{calendar_reschedule,required}')::boolean,false) THEN
      v_src:=v_result#>'{calendar_reschedule,source}';
      v_rep:=v_result#>'{calendar_reschedule,replacement}';
      IF coalesce((v_src->>'delete_required')::boolean,false) THEN
        PERFORM core.enqueue_calendar_sync_job_v2(p_business_id,(v_src->>'appointment_id')::uuid,'DELETE',p_execution_ref,NULL);
      END IF;
      IF coalesce((v_rep->>'create_required')::boolean,false) THEN
        PERFORM core.enqueue_calendar_sync_job_v2(p_business_id,(v_rep->>'appointment_id')::uuid,'CREATE',p_execution_ref,NULL);
      END IF;
    END IF;

    -- A confirmed slot may have originated from our waitlist engine.
    IF v_action='SELECT_SLOT' THEN
      BEGIN
        v_offer:=coalesce(
          nullif(v_result#>>'{result,slot_offer_id}','')::uuid,
          nullif(v_result#>>'{result,selection,slot_offer_id}','')::uuid
        );
        v_appt:=coalesce(
          nullif(v_result#>>'{result,appointment,appointment_id}','')::uuid,
          nullif(v_result#>>'{result,replacement,appointment_id}','')::uuid,
          nullif(v_result#>>'{result,replacement_appointment_id}','')::uuid
        );
        IF v_offer IS NOT NULL AND v_appt IS NOT NULL THEN
          PERFORM core.mark_waitlist_booked_from_offer_v1(p_business_id,p_customer_id,v_offer,v_appt);
          PERFORM core.attribute_campaign_conversion_v1(p_business_id,p_customer_id,v_appt,'APPOINTMENT_CONFIRMED');
        END IF;
      EXCEPTION WHEN OTHERS THEN
        PERFORM core.record_automation_incident_v1(
          p_business_id,'WARNING','CORE_RUNTIME',p_execution_ref,'ATTRIBUTION','POST_CONFIRM_HOOK_FAILED',SQLERRM,
          jsonb_build_object('execution',v_result)
        );
      END;
    END IF;

    -- Customer-originated cancellation gets its confirmation from the same conversational turn.
    -- Proactive professional/business cancellation is handled by the Control Plane helper.
    RETURN v_result;
END;
$function$;

CREATE OR REPLACE FUNCTION core.finalize_conversation_job_final(
    p_job_id UUID,p_command JSONB,p_execution JSONB,p_response JSONB,p_execution_ref TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
VOLATILE
AS $function$
DECLARE
    v_job core.integration_jobs%ROWTYPE;
    v_payload JSONB;
    v_ctx JSONB;
    v_final JSONB;
    v_delivery JSONB;
    v_kind TEXT;
    v_route TEXT;
    v_response_type TEXT;
    v_should_send BOOLEAN;
BEGIN
    SELECT * INTO v_job FROM core.integration_jobs WHERE id=p_job_id FOR UPDATE;
    IF NOT FOUND THEN RETURN jsonb_build_object('ok',false,'code','JOB_NOT_FOUND'); END IF;
    IF v_job.status<>'RUNNING' THEN RETURN jsonb_build_object('ok',false,'code','JOB_NOT_RUNNING','status',v_job.status); END IF;

    v_payload:=v_job.payload;
    v_ctx:=v_payload->'context';
    v_kind:=coalesce(p_command->>'kind','NEED_INFORMATION');
    v_route:=CASE WHEN v_kind='BUSINESS_ACTION' THEN 'CORE' WHEN v_kind='HUMAN_HANDOFF' THEN 'HUMAN_HANDOFF' ELSE 'DIRECT_RESPONSE' END;
    v_response_type:=coalesce(p_response->>'response_type','GENERAL');
    v_should_send:=coalesce((p_response->>'should_send')::boolean,true);

    IF v_kind='HUMAN_HANDOFF' THEN
      UPDATE core.conversations SET automation_mode='HUMAN',pending_action=NULL,updated_at=now()
      WHERE business_id=(v_ctx#>>'{business,id}')::uuid AND id=(v_ctx#>>'{conversation,id}')::uuid;
    END IF;

    v_final:=core.finalize_assistant_turn(
      (v_ctx#>>'{business,id}')::uuid,
      (v_ctx#>>'{conversation,id}')::uuid,
      (v_ctx#>>'{customer,id}')::uuid,
      (v_ctx#>>'{customer,channel_id}')::uuid,
      v_ctx#>>'{channel,channel_type}',
      v_ctx#>>'{channel,provider}',
      (v_ctx#>>'{turn,message_id}')::uuid,
      p_command->>'intent',
      coalesce((p_command->>'confidence')::numeric,0),
      v_kind,
      v_route,
      coalesce(p_command->>'action','NONE'),
      p_response->>'text',
      v_response_type,
      coalesce(p_response->>'source','RESPONSE_ENGINE'),
      v_should_send
    );

    IF coalesce((v_final->>'ok')::boolean,false) IS NOT TRUE THEN
      PERFORM core.fail_integration_job_v1(p_job_id,'FINALIZE_ASSISTANT_TURN_FAILED',jsonb_build_object('finalization',v_final));
      RETURN jsonb_build_object('ok',false,'code','FINALIZATION_FAILED','finalization',v_final);
    END IF;

    IF v_should_send AND nullif(p_response->>'text','') IS NOT NULL THEN
      v_delivery:=core.queue_outbound_notification_v3(
        (v_ctx#>>'{business,id}')::uuid,
        (v_ctx#>>'{customer,id}')::uuid,
        'CONVERSATION_RESPONSE',
        jsonb_build_object('text',p_response->>'text','metadata',jsonb_build_object('turn_job_id',p_job_id)),
        'TURN:'||(v_ctx#>>'{turn,message_id}'),p_execution_ref,
        coalesce(p_execution,'{}'::jsonb),v_response_type
      );
      IF coalesce((v_delivery->>'ok')::boolean,false) IS NOT TRUE THEN
        PERFORM core.fail_integration_job_v1(p_job_id,'OUTBOUND_QUEUE_FAILED',jsonb_build_object('delivery',v_delivery));
        RETURN jsonb_build_object('ok',false,'code','OUTBOUND_QUEUE_FAILED','delivery',v_delivery);
      END IF;
    END IF;

    PERFORM core.complete_integration_job_v1(
      p_job_id,jsonb_build_object('command',p_command,'execution',p_execution,'response',p_response,'finalization',v_final,'delivery',v_delivery)
    );
    RETURN jsonb_build_object('ok',true,'code','TURN_FINALIZED','finalization',v_final,'delivery',v_delivery);
END;
$function$;


-- ============================================================
-- SOURCE: 055_control_plane_final.sql
-- ============================================================
-- 055_control_plane_final.sql
-- Complete audited Control Plane for ML Admin / ML Manager / ML Employee.

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


-- ============================================================
-- SOURCE: 056_whatsapp_webhook_final.sql
-- ============================================================
-- 056_whatsapp_webhook_final.sql
-- Unified entry point for inbound WhatsApp messages and provider delivery receipts.

CREATE TABLE IF NOT EXISTS core.webhook_events (
    id BIGSERIAL PRIMARY KEY,
    provider TEXT NOT NULL,
    event_key TEXT,
    event_type TEXT NOT NULL,
    payload JSONB NOT NULL DEFAULT '{}'::jsonb,
    processed BOOLEAN NOT NULL DEFAULT false,
    result JSONB,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    processed_at TIMESTAMPTZ
);
CREATE UNIQUE INDEX IF NOT EXISTS uq_webhook_events_provider_key
ON core.webhook_events(provider,event_key) WHERE event_key IS NOT NULL;

CREATE OR REPLACE FUNCTION core.ingest_whatsapp_webhook_final(
    p_event JSONB,p_execution_ref TEXT
)
RETURNS JSONB LANGUAGE plpgsql VOLATILE AS $function$
DECLARE
    v_type TEXT:=upper(coalesce(p_event->>'event_type','IGNORE'));
    v_key TEXT:=nullif(p_event->>'event_key','');
    v_event_id BIGINT;
    v_result JSONB;
BEGIN
    BEGIN
      INSERT INTO core.webhook_events(provider,event_key,event_type,payload)
      VALUES('META',v_key,v_type,coalesce(p_event,'{}'::jsonb))
      RETURNING id INTO v_event_id;
    EXCEPTION WHEN unique_violation THEN
      SELECT result INTO v_result FROM core.webhook_events WHERE provider='META' AND event_key=v_key;
      RETURN coalesce(v_result,jsonb_build_object('ok',true,'code','WEBHOOK_DUPLICATE'));
    END;

    IF v_type='DELIVERY_STATUS' THEN
      v_result:=core.ingest_whatsapp_delivery_status_v1(
        p_event->>'external_message_id',p_event->>'status',nullif(p_event->>'provider_timestamp','')::timestamptz,
        coalesce(p_event->'raw_payload','{}'::jsonb)
      );
    ELSIF v_type='INBOUND_MESSAGE' THEN
      v_result:=core.ingest_whatsapp_event_v1(
        p_event#>>'{channel,external_channel_id}',p_event#>>'{channel,type}',p_event#>>'{channel,provider}',
        p_event#>>'{customer,external_user_id}',p_event#>>'{customer,profile_name}',
        p_event#>>'{message,idempotency_key}',p_event#>>'{message,external_message_id}',p_event#>>'{message,type}',
        coalesce(p_event#>'{message,interaction}','{}'::jsonb),coalesce(p_event#>'{message,media}','{}'::jsonb),
        jsonb_build_object('text',p_event#>>'{message,text}','raw_payload',coalesce(p_event#>'{message,raw_payload}','{}'::jsonb),
                           'reply_to_external_message_id',p_event#>>'{message,reply_to_external_message_id}'),
        nullif(p_event#>>'{message,provider_timestamp}','')::timestamptz,p_execution_ref
      );
    ELSE
      v_result:=jsonb_build_object('ok',true,'code','WEBHOOK_EVENT_IGNORED','event_type',v_type);
    END IF;

    UPDATE core.webhook_events SET processed=true,result=v_result,processed_at=now() WHERE id=v_event_id;
    RETURN v_result;
EXCEPTION WHEN OTHERS THEN
    UPDATE core.webhook_events SET processed=true,result=jsonb_build_object('ok',false,'code','WEBHOOK_PROCESSING_ERROR','message',SQLERRM),processed_at=now()
    WHERE id=v_event_id;
    RAISE;
END;
$function$;


-- ============================================================
-- SOURCE: 057_ai_runtime_policy_final.sql
-- ============================================================
-- 057_ai_runtime_policy_final.sql
-- Central model policy. GPT-5.6 Luna is the production default for cost-sensitive/high-volume work.

CREATE TABLE IF NOT EXISTS core.ai_runtime_policies (
    business_id UUID PRIMARY KEY REFERENCES core.businesses(id) ON DELETE CASCADE,
    orchestrator_model TEXT NOT NULL DEFAULT 'gpt-5.6-luna',
    response_model TEXT NOT NULL DEFAULT 'gpt-5.6-luna',
    media_model TEXT NOT NULL DEFAULT 'gpt-5.6-luna',
    transcription_model TEXT NOT NULL DEFAULT 'gpt-4o-mini-transcribe',
    orchestrator_reasoning_effort TEXT NOT NULL DEFAULT 'medium'
        CHECK (orchestrator_reasoning_effort IN ('none','low','medium','high','xhigh','max')),
    response_reasoning_effort TEXT NOT NULL DEFAULT 'low'
        CHECK (response_reasoning_effort IN ('none','low','medium','high','xhigh','max')),
    max_orchestrator_output_tokens INTEGER NOT NULL DEFAULT 1800 CHECK (max_orchestrator_output_tokens BETWEEN 256 AND 16000),
    max_response_output_tokens INTEGER NOT NULL DEFAULT 900 CHECK (max_response_output_tokens BETWEEN 128 AND 8000),
    enabled BOOLEAN NOT NULL DEFAULT TRUE,
    metadata JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

DROP TRIGGER IF EXISTS trg_ai_runtime_policies_updated_at
ON core.ai_runtime_policies;

CREATE TRIGGER trg_ai_runtime_policies_updated_at
BEFORE UPDATE ON core.ai_runtime_policies
FOR EACH ROW
EXECUTE FUNCTION core.set_updated_at();

INSERT INTO core.ai_runtime_policies (business_id)
SELECT b.id
FROM core.businesses b
ON CONFLICT (business_id) DO NOTHING;

CREATE OR REPLACE FUNCTION core.get_ai_runtime_policy_v1(p_business_id UUID)
RETURNS JSONB
LANGUAGE sql
STABLE
AS $function$
SELECT jsonb_build_object(
    'orchestrator_model', p.orchestrator_model,
    'response_model', p.response_model,
    'media_model', p.media_model,
    'transcription_model', p.transcription_model,
    'orchestrator_reasoning_effort', p.orchestrator_reasoning_effort,
    'response_reasoning_effort', p.response_reasoning_effort,
    'max_orchestrator_output_tokens', p.max_orchestrator_output_tokens,
    'max_response_output_tokens', p.max_response_output_tokens,
    'enabled', p.enabled
)
FROM core.ai_runtime_policies p
WHERE p.business_id = p_business_id;
$function$;

