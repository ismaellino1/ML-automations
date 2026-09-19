-- P0.8 — TEST_MATRIX.md scenarios covered here:
--   #9  (partial) provider failure with retry - backoff schedule and
--       eventual DEAD status at max_attempts.
--   #11 two concurrent workers never claim the same job.
--   #14 dead-letter is reached deterministically, not accidentally.
--   #15 a job stuck RUNNING behind an expired lease (e.g. n8n restarted
--       mid-processing) is recovered and becomes claimable again.
-- See docs/P0_TEST_MATRIX_COVERAGE.md for the full 15-item mapping,
-- including which scenarios are out of scope for P0 (appointments/AI-
-- behavior domain, untouched by any P0 fix) and deferred to P1.

CREATE EXTENSION IF NOT EXISTS pgtap;

BEGIN;

SELECT plan(9);

INSERT INTO core.businesses (id, business_code, name)
VALUES ('00000000-0000-0000-0000-0000000008a1', 'BIZ_P08', 'Business P0.8');

-- =======================================================================
-- #9 / #14 — retry backoff schedule + eventual dead-letter.
-- fail_integration_job_v1's own documented schedule: attempt 1->5s,
-- 2->15s, 3->60s, 4->300s, 5->900s, 6+->3600s; DEAD once attempts>=max.
-- =======================================================================
SELECT core.enqueue_integration_job_v1(
  '00000000-0000-0000-0000-0000000008a1'::uuid, 'TEST_RETRY_JOB'::text, 'DO_THING'::text, '{}'::jsonb,
  NULL::text, NULL::text, NULL::uuid, 100, 3  -- max_attempts=3, so the 3rd failure goes DEAD
) AS job_id \gset

-- Attempt 1: claim + fail.
SELECT core.claim_integration_jobs_v1('TEST_RETRY_JOB', 1, 'worker-a', 120);
SELECT core.fail_integration_job_v1(:'job_id'::uuid, 'transient provider error', '{}'::jsonb);

SELECT is(
  (SELECT status FROM core.integration_jobs WHERE id = :'job_id'::uuid),
  'RETRY',
  'first failure schedules a RETRY (attempts=1 < max_attempts=3)'
);

SELECT ok(
  (SELECT next_attempt_at FROM core.integration_jobs WHERE id = :'job_id'::uuid) <= now() + interval '10 seconds',
  'first retry backoff is short (~5s), so it will be claimable again soon'
);

-- Force it claimable now (skip the real wait) and fail again.
UPDATE core.integration_jobs SET next_attempt_at = now() WHERE id = :'job_id'::uuid;
SELECT core.claim_integration_jobs_v1('TEST_RETRY_JOB', 1, 'worker-a', 120);
SELECT core.fail_integration_job_v1(:'job_id'::uuid, 'transient provider error again', '{}'::jsonb);

SELECT is(
  (SELECT status FROM core.integration_jobs WHERE id = :'job_id'::uuid),
  'RETRY',
  'second failure still retries (attempts=2 < max_attempts=3)'
);

-- Third failure hits max_attempts -> DEAD.
UPDATE core.integration_jobs SET next_attempt_at = now() WHERE id = :'job_id'::uuid;
SELECT core.claim_integration_jobs_v1('TEST_RETRY_JOB', 1, 'worker-a', 120);
SELECT core.fail_integration_job_v1(:'job_id'::uuid, 'still failing', '{}'::jsonb);

SELECT is(
  (SELECT status FROM core.integration_jobs WHERE id = :'job_id'::uuid),
  'DEAD',
  'the third failure at max_attempts=3 reaches DEAD deterministically - dead-letter works'
);

SELECT is(
  (SELECT count(*)::int FROM core.integration_job_attempts WHERE job_id = :'job_id'::uuid),
  3,
  'all 3 attempts are recorded in the audit history - a dead job is fully explainable'
);

-- =======================================================================
-- #15 — recovery after an n8n restart: a job stuck RUNNING with an
-- expired lease must be released and become claimable again.
-- =======================================================================
SELECT core.enqueue_integration_job_v1(
  '00000000-0000-0000-0000-0000000008a1'::uuid, 'TEST_STUCK_JOB', 'DO_THING', '{}'::jsonb
) AS stuck_job_id \gset

SELECT core.claim_integration_jobs_v1('TEST_STUCK_JOB', 1, 'worker-that-crashed', 120);

-- Simulate the crash: the lease is still "RUNNING" but has expired, exactly
-- as it would look after n8n (or the worker process) died mid-processing
-- without ever calling complete/fail.
UPDATE core.integration_jobs SET lease_expires_at = now() - interval '1 minute' WHERE id = :'stuck_job_id'::uuid;

SELECT core.release_expired_job_leases(1000);

SELECT is(
  (SELECT status FROM core.integration_jobs WHERE id = :'stuck_job_id'::uuid),
  'RETRY',
  'a job behind an expired lease is released back to RETRY, not left stuck RUNNING forever'
);

SELECT ok(
  (SELECT lease_owner FROM core.integration_jobs WHERE id = :'stuck_job_id'::uuid) IS NULL,
  'the stale lease_owner is cleared'
);

-- A fresh worker (simulating n8n having restarted) can now claim it.
SELECT results_eq(
  $$ SELECT count(*)::int FROM core.claim_integration_jobs_v1('TEST_STUCK_JOB', 1, 'worker-fresh', 120) $$,
  $$ VALUES (1) $$,
  'the recovered job is claimable again by a fresh worker after the simulated restart'
);

-- =======================================================================
-- #11 — two concurrent workers must never claim the same job. This is a
-- real cross-connection race, not something expressible inside a single
-- transaction, so it lives in a separate script:
-- supabase/tests/p0/008b_concurrent_claim_check.sh
-- =======================================================================
SELECT pass('see supabase/tests/p0/008b_concurrent_claim_check.sh for the real concurrent-claim race proof');

SELECT * FROM finish();
ROLLBACK;
