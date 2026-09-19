#!/usr/bin/env bash
# Real cross-connection concurrency proof for P0.2. pgTAP tests run inside a
# single transaction/connection and cannot express true concurrent races, so
# this is a standalone script: two independent psql connections fire the
# SAME webhook event (identical event_key) at core.ingest_whatsapp_webhook_final
# as close to simultaneously as the shell can manage, against a real,
# persistent (not rolled back) database. Asserts: exactly one webhook_events
# row exists afterward, no matter which of the two "won" the race.
#
# Not part of run_local_harness.sh's automatic *.sql loop (a .sh file, and a
# genuine concurrency test doesn't belong inside a single transaction) - run
# manually: bash supabase/tests/p0/002b_concurrency_check.sh
set -euo pipefail

export PGHOST="${PGHOST:-/tmp/ml_pg_test}"
export PGPORT="${PGPORT:-55432}"
export PGUSER="${PGUSER:-postgres}"
DB=ml_p0_test

FIXTURE_SQL="
INSERT INTO core.businesses (id, business_code, name)
VALUES ('00000000-0000-0000-0000-0000000002a1', 'BIZ_CONC', 'Business Concurrency')
ON CONFLICT (id) DO NOTHING;
INSERT INTO core.business_settings (business_id)
VALUES ('00000000-0000-0000-0000-0000000002a1') ON CONFLICT DO NOTHING;
INSERT INTO core.business_channels (id, business_id, channel_type, provider, external_channel_id, status)
VALUES ('00000000-0000-0000-0000-0000000002c1', '00000000-0000-0000-0000-0000000002a1', 'WHATSAPP', 'META', 'PHONE_CONC', 'ACTIVE')
ON CONFLICT (id) DO NOTHING;
"

RACE_SQL="SELECT core.ingest_whatsapp_webhook_final(
  jsonb_build_object(
    'event_type','DELIVERY_STATUS','event_key','TEST:RACE:1',
    'channel', jsonb_build_object('external_channel_id','PHONE_CONC','provider','META'),
    'external_message_id','wamid.RACE.1','status','SENT','provider_timestamp',to_char(now(),'YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"')
  ), 'exec-ref-race'
);"

echo "== fixture =="
psql -d "$DB" -v ON_ERROR_STOP=1 -c "$FIXTURE_SQL" >/dev/null

echo "== firing two concurrent calls with the identical event_key =="
psql -d "$DB" -c "$RACE_SQL" > /tmp/race_a.out 2>&1 &
PID_A=$!
psql -d "$DB" -c "$RACE_SQL" > /tmp/race_b.out 2>&1 &
PID_B=$!
wait "$PID_A"
wait "$PID_B"

echo "-- call A output --"; cat /tmp/race_a.out
echo "-- call B output --"; cat /tmp/race_b.out

COUNT=$(psql -d "$DB" -t -A -c "SELECT count(*) FROM core.webhook_events WHERE provider='META' AND event_key='TEST:RACE:1';")

echo "== webhook_events rows for TEST:RACE:1: $COUNT =="
if [ "$COUNT" -eq 1 ]; then
  echo "PASS: exactly one row survived the concurrent race - the UNIQUE(provider,event_key) constraint serialized it correctly."
  exit 0
else
  echo "FAIL: expected exactly 1 row, found $COUNT - concurrency safety is broken."
  exit 1
fi
