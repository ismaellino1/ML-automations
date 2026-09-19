#!/usr/bin/env bash
# Rebuilds a throwaway local Postgres database from scratch and applies:
#   1. the synthetic prerequisite fixture (test-only, never a migration)
#   2. the real messaging-chain migrations (007, 027)
#   3. the real overlay migrations (043-050)
#   4. 051 (whichever version currently sits in supabase/migrations/ -
#      this is what lets the same script serve as both the "reproduce the
#      bug" run and, after the fix lands, the permanent regression run)
#   5. any files under supabase/tests/p0/*.sql, in name order
#
# Requires: PGHOST/PGPORT pointing at a running local Postgres (see the
# session's own setup of /tmp/ml_pg_test). Not meant to run against
# STAGING/PROD - this is a local, ephemeral, disposable database.
set -euo pipefail

export PGHOST="${PGHOST:-/tmp/ml_pg_test}"
export PGPORT="${PGPORT:-55432}"
export PGUSER="${PGUSER:-postgres}"
DB=ml_p0_test

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
MIGRATIONS="$ROOT/supabase/migrations"
FIXTURE="$ROOT/supabase/tests/local_harness/00_synthetic_prereqs.sql"
P0_TESTS="$ROOT/supabase/tests/p0"

echo "== dropping/recreating $DB =="
psql -d postgres -v ON_ERROR_STOP=1 -c "DROP DATABASE IF EXISTS $DB;" >/dev/null
psql -d postgres -v ON_ERROR_STOP=1 -c "CREATE DATABASE $DB;" >/dev/null

run() {
  local file="$1"
  echo "-- applying: ${file#$ROOT/} --"
  psql -d "$DB" -v ON_ERROR_STOP=1 -f "$file"
}

run "$FIXTURE"
run "$MIGRATIONS/007_messaging_foundation.sql"
run "$MIGRATIONS/027_assistant_messaging_engine.sql"
run "$MIGRATIONS/043_prod_job_queue.sql"
run "$MIGRATIONS/044_catalog_knowledge_media.sql"
run "$MIGRATIONS/045_marketing_campaigns.sql"
run "$MIGRATIONS/046_automation_reminders.sql"
run "$MIGRATIONS/047_rbac_control_plane.sql"
run "$MIGRATIONS/048_runtime_v5_adapters.sql"
run "$MIGRATIONS/049_observability.sql"
run "$MIGRATIONS/050_security_rls.sql"
run "$MIGRATIONS/051_whatsapp_calendar_hardening.sql"
run "$MIGRATIONS/052_engagement_automation_v3.sql"
run "$MIGRATIONS/056_whatsapp_webhook_final.sql"
run "$MIGRATIONS/057_ai_runtime_policy_final.sql"
# NOTE: 053 (waitlist), 054 (runtime_final) and 055 (control_plane_final)
# are intentionally NOT applied by this harness. Unlike PL/pgSQL function
# bodies (which are late-bound and apply fine even when a function they
# call doesn't exist yet), 053's CREATE TABLE has real FOREIGN KEY
# constraints against core.services/core.professionals - the full
# appointments-domain schema (006,013,015-019,026,029,035-042), which this
# harness does not build because P0.1-P0.4/P0.8's scope is the messaging/
# job-queue/observability chain, not appointments. Building that fuller
# fixture (or, better, applying the REAL 006 etc. migrations directly) is
# legitimate future work for a P1 integration harness - see
# docs/AUDIT/PHASE_A.md and the P0 completion report for this boundary.

if [ -d "$P0_TESTS" ]; then
  for f in "$P0_TESTS"/*.sql; do
    [ -e "$f" ] || continue
    echo "== running test: ${f#$ROOT/} =="
    psql -d "$DB" -v ON_ERROR_STOP=1 -f "$f"
  done
fi

echo "== harness completed =="
