-- P0.4 — core.complete_integration_job_v1 must preserve worker_ref (the
-- lease_owner at the time of completion) in the job's attempt history.

CREATE EXTENSION IF NOT EXISTS pgtap;

BEGIN;

SELECT plan(4);

INSERT INTO core.businesses (id, business_code, name)
VALUES ('00000000-0000-0000-0000-0000000004a1', 'BIZ_P04', 'Business P0.4');

SELECT core.enqueue_integration_job_v1(
  '00000000-0000-0000-0000-0000000004a1'::uuid, 'TEST_JOB', 'DO_THING', '{}'::jsonb
) AS job_id \gset

SELECT core.claim_integration_jobs_v1('TEST_JOB', 1, 'worker-42', 120);

SELECT is(
  (SELECT lease_owner FROM core.integration_jobs WHERE id = :'job_id'::uuid),
  'worker-42',
  'sanity: the job is leased to worker-42 while RUNNING'
);

SELECT core.complete_integration_job_v1(:'job_id'::uuid, '{"result":"ok"}'::jsonb);

SELECT is(
  (SELECT lease_owner FROM core.integration_jobs WHERE id = :'job_id'::uuid),
  NULL,
  'lease_owner is correctly released (NULL) on the job row after completion'
);

SELECT is(
  (SELECT worker_ref FROM core.integration_job_attempts WHERE job_id = :'job_id'::uuid AND outcome = 'SUCCEEDED'),
  'worker-42',
  'the attempt history preserves which worker actually completed the job - this is the P0.4 fix'
);

SELECT is(
  (SELECT count(*)::int FROM core.integration_job_attempts WHERE job_id = :'job_id'::uuid),
  1,
  'exactly one attempt row was recorded'
);

SELECT * FROM finish();
ROLLBACK;
