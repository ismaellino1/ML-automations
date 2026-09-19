
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

-- P0.8 CORRECTION (2026-09-19): p_priority was SMALLINT. Postgres does not
-- implicitly coerce a bare integer literal (e.g. `80`) to smallint during
-- function overload resolution (only quoted/"unknown"-typed literals, or an
-- explicit ::smallint cast, resolve) - only an assignment-level cast, which
-- does not apply to function-call argument matching. Every one of this
-- function's 12 call sites across 044/045/048/051/052/054 passes a bare
-- integer literal for this argument (e.g. `...,80,5,now(),...`), so EVERY
-- call was failing at runtime with "function does not exist" - discovered
-- only by actually executing this migration chain against a real Postgres
-- engine (see supabase/tests/p0/009_p0_8_campaigns_and_media.sql), not by
-- reading the SQL text. Fixed by widening the parameter to INTEGER (the
-- underlying core.integration_jobs.priority column stays SMALLINT - integer
-- -> smallint on INSERT is a normal, always-allowed assignment cast; the
-- problem was specific to function-call overload resolution, not storage).
-- This is a single fix at the signature, not 12 individual call-site casts.
CREATE OR REPLACE FUNCTION core.enqueue_integration_job_v1(
 p_business_id UUID,p_job_type TEXT,p_operation TEXT,p_payload JSONB,
 p_dedupe_key TEXT DEFAULT NULL,p_subject_type TEXT DEFAULT NULL,p_subject_id UUID DEFAULT NULL,
 p_priority INTEGER DEFAULT 100,p_max_attempts INTEGER DEFAULT 8,p_next_attempt_at TIMESTAMPTZ DEFAULT now(),
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

-- P0.4 CORRECTION (2026-09-19): the original version captured the job row
-- via `UPDATE ... SET lease_owner=NULL ... RETURNING * INTO v`, so v.lease_owner
-- was already NULL by the time it was written to integration_job_attempts -
-- every successful completion lost its worker attribution (worker_ref
-- always NULL), unlike fail_integration_job_v1 below which correctly reads
-- the row BEFORE nulling it. Fixed by matching that same SELECT ... FOR
-- UPDATE first, capture, then UPDATE idiom. See docs/AUDIT/PHASE_A.md D.7
-- and supabase/tests/p0/004_p0_4_job_worker_ref.sql.
CREATE OR REPLACE FUNCTION core.complete_integration_job_v1(
 p_job_id UUID,p_provider_response JSONB DEFAULT '{}'::jsonb
) RETURNS JSONB LANGUAGE plpgsql AS $$
DECLARE v core.integration_jobs%rowtype;
BEGIN
 SELECT * INTO v FROM core.integration_jobs WHERE id=p_job_id AND status='RUNNING' FOR UPDATE;
 IF NOT FOUND THEN RETURN jsonb_build_object('ok',false,'code','JOB_NOT_RUNNING'); END IF;
 UPDATE core.integration_jobs SET status='SUCCEEDED',provider_response=coalesce(p_provider_response,'{}'::jsonb),
   completed_at=now(),lease_owner=NULL,lease_expires_at=NULL,updated_at=now()
 WHERE id=v.id;
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
