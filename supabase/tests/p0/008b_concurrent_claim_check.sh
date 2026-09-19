#!/usr/bin/env bash
# TEST_MATRIX.md #11: two concurrent workers must never claim the same job.
# core.claim_integration_jobs_v1 relies on `FOR UPDATE SKIP LOCKED` - this
# proves it for real across two independent connections, not just by
# reading the SQL and trusting the pattern. Not part of the automatic
# *.sql harness loop (needs true cross-connection concurrency) - run
# manually: bash supabase/tests/p0/008b_concurrent_claim_check.sh
set -euo pipefail

export PGHOST="${PGHOST:-/tmp/ml_pg_test}"
export PGPORT="${PGPORT:-55432}"
export PGUSER="${PGUSER:-postgres}"
DB=ml_p0_test

FIXTURE_SQL="
INSERT INTO core.businesses (id, business_code, name)
VALUES ('00000000-0000-0000-0000-0000000009a1', 'BIZ_CLAIM', 'Business Claim Race')
ON CONFLICT (id) DO NOTHING;
DELETE FROM core.integration_jobs WHERE job_type = 'TEST_CLAIM_RACE';
INSERT INTO core.integration_jobs (business_id, job_type, operation, payload)
SELECT '00000000-0000-0000-0000-0000000009a1', 'TEST_CLAIM_RACE', 'DO_THING', '{}'::jsonb
FROM generate_series(1,5);
"

claim_sql() {
  echo "SELECT jsonb_agg((job->>'id')::uuid) FROM core.claim_integration_jobs_v1('TEST_CLAIM_RACE', 3, '$1', 120) q(job);"
}

echo "== fixture: 5 pending jobs =="
psql -d "$DB" -v ON_ERROR_STOP=1 -c "$FIXTURE_SQL" >/dev/null

echo "== two workers racing to claim (3 each, 5 available - overlap is only possible if the race is broken) =="
psql -d "$DB" -t -A -c "$(claim_sql worker-race-a)" > /tmp/claim_a.out &
PID_A=$!
psql -d "$DB" -t -A -c "$(claim_sql worker-race-b)" > /tmp/claim_b.out &
PID_B=$!
wait "$PID_A"
wait "$PID_B"

echo "-- worker A claimed --"; cat /tmp/claim_a.out
echo "-- worker B claimed --"; cat /tmp/claim_b.out

OVERLAP=$(psql -d "$DB" -t -A -c "
WITH a AS (SELECT jsonb_array_elements_text('$(cat /tmp/claim_a.out | tr -d '\n')'::jsonb) AS id),
     b AS (SELECT jsonb_array_elements_text('$(cat /tmp/claim_b.out | tr -d '\n')'::jsonb) AS id)
SELECT count(*) FROM a JOIN b USING (id);
")

TOTAL_RUNNING=$(psql -d "$DB" -t -A -c "SELECT count(*) FROM core.integration_jobs WHERE job_type='TEST_CLAIM_RACE' AND status='RUNNING';")

echo "== overlap between the two claims: $OVERLAP  |  total jobs now RUNNING: $TOTAL_RUNNING =="
if [ "$OVERLAP" -eq 0 ] && [ "$TOTAL_RUNNING" -eq 5 ]; then
  echo "PASS: zero overlap, all 5 jobs claimed exactly once across the two concurrent workers."
  exit 0
else
  echo "FAIL: overlap=$OVERLAP running=$TOTAL_RUNNING - concurrent claim safety is broken."
  exit 1
fi
