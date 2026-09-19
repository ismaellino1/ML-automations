-- P0.2 — core.ingest_whatsapp_webhook_final must stay auditable and keep
-- its dedupe protection even when downstream processing fails.

CREATE EXTENSION IF NOT EXISTS pgtap;

BEGIN;

SELECT plan(11);

INSERT INTO core.businesses (id, business_code, name)
VALUES ('00000000-0000-0000-0000-0000000001a1', 'BIZ_P02', 'Business P0.2');
INSERT INTO core.business_settings (business_id) VALUES ('00000000-0000-0000-0000-0000000001a1');
INSERT INTO core.business_channels (id, business_id, channel_type, provider, external_channel_id, status)
VALUES ('00000000-0000-0000-0000-0000000001c1', '00000000-0000-0000-0000-0000000001a1', 'WHATSAPP', 'META', 'PHONE_P02', 'ACTIVE');
INSERT INTO core.customers (id, business_id, name)
VALUES ('00000000-0000-0000-0000-0000000001d1', '00000000-0000-0000-0000-0000000001a1', 'Customer P0.2');
INSERT INTO core.customer_channels (id, business_id, customer_id, channel_type, provider, external_user_id)
VALUES ('00000000-0000-0000-0000-0000000001e1', '00000000-0000-0000-0000-0000000001a1', '00000000-0000-0000-0000-0000000001d1', 'WHATSAPP', 'META', '5511900000099');

-- =======================================================================
-- 1. "EVENTO JÁ PROCESSADO" / "WEBHOOK DUPLICADO": a valid DELIVERY_STATUS
--    event delivered twice with the identical event_key must be processed
--    once and the second delivery must return the cached result, not error
--    and not reprocess.
-- =======================================================================
SELECT core.ingest_whatsapp_webhook_final(
  jsonb_build_object(
    'event_type','DELIVERY_STATUS','event_key','TEST:DUP:1',
    'channel', jsonb_build_object('external_channel_id','PHONE_P02','provider','META'),
    'external_message_id','wamid.DUP.1','status','SENT','provider_timestamp',to_char(now(),'YYYY-MM-DD"T"HH24:MI:SS"Z"')
  ), 'exec-ref-1'
) AS first_call \gset

SELECT is(
  (:'first_call'::jsonb->>'code'),
  'DELIVERY_EVENT_PENDING_BIND',
  'a delivery status for a message we never sent/bound resolves the tenant and is deferred cleanly (not an error) on first delivery'
);
-- (There is no bound outbound message for wamid.DUP.1 here, so
-- apply_message_delivery_status correctly reports the pending-bind case;
-- what this test is really proving is dedupe/replay behavior, so we assert
-- on the webhook_events row, not on message-side effects.)

SELECT is(
  (SELECT count(*)::int FROM core.webhook_events WHERE provider='META' AND event_key='TEST:DUP:1'),
  1,
  'exactly one webhook_events row exists after the first delivery'
);

SELECT core.ingest_whatsapp_webhook_final(
  jsonb_build_object(
    'event_type','DELIVERY_STATUS','event_key','TEST:DUP:1',
    'channel', jsonb_build_object('external_channel_id','PHONE_P02','provider','META'),
    'external_message_id','wamid.DUP.1','status','SENT','provider_timestamp',to_char(now(),'YYYY-MM-DD"T"HH24:MI:SS"Z"')
  ), 'exec-ref-2'
) AS second_call \gset

SELECT is(
  (:'second_call'::jsonb->>'code'),
  (:'first_call'::jsonb->>'code'),
  'a duplicate webhook delivery (same event_key) returns the cached result, not a fresh attempt'
);

SELECT is(
  (SELECT count(*)::int FROM core.webhook_events WHERE provider='META' AND event_key='TEST:DUP:1'),
  1,
  'still exactly one webhook_events row after the duplicate delivery - no second row was ever created'
);

-- =======================================================================
-- 2. "HANDLER FALHANDO": force a genuine unhandled exception inside the
--    dispatched processing (an unparseable provider_timestamp raises
--    invalid_datetime_format) and confirm the webhook_events audit row
--    from the outer INSERT survives it - this is the exact P0.1/D.1 defect.
-- =======================================================================
SELECT core.ingest_whatsapp_webhook_final(
  jsonb_build_object(
    'event_type','DELIVERY_STATUS','event_key','TEST:FAIL:1',
    'channel', jsonb_build_object('external_channel_id','PHONE_P02','provider','META'),
    'external_message_id','wamid.FAIL.1','status','SENT','provider_timestamp','THIS-IS-NOT-A-TIMESTAMP'
  ), 'exec-ref-3'
) AS failing_call \gset

SELECT is(
  (:'failing_call'::jsonb->>'code'),
  'WEBHOOK_PROCESSING_ERROR',
  'a downstream exception is caught and returned as a structured error, not raised to the caller'
);

SELECT is(
  (SELECT count(*)::int FROM core.webhook_events WHERE provider='META' AND event_key='TEST:FAIL:1'),
  1,
  'the audit row for the FAILED event still exists - this is the core P0.2 fix'
);

SELECT is(
  (SELECT processed FROM core.webhook_events WHERE provider='META' AND event_key='TEST:FAIL:1'),
  true,
  'the failed event is marked processed (with an error result), not left in limbo'
);

SELECT is(
  (SELECT result->>'code' FROM core.webhook_events WHERE provider='META' AND event_key='TEST:FAIL:1'),
  'WEBHOOK_PROCESSING_ERROR',
  'the recorded result on the audit row itself reflects the real failure - an operator can see exactly what happened'
);

-- =======================================================================
-- 3. "RETRY APÓS FALHA": Meta retries the identical failing delivery
--    (same event_key) - dedupe must still catch it and it must NOT attempt
--    to reprocess (and therefore not error again either).
-- =======================================================================
SELECT lives_ok(
  $$ SELECT core.ingest_whatsapp_webhook_final(
       jsonb_build_object(
         'event_type','DELIVERY_STATUS','event_key','TEST:FAIL:1',
         'channel', jsonb_build_object('external_channel_id','PHONE_P02','provider','META'),
         'external_message_id','wamid.FAIL.1','status','SENT','provider_timestamp','THIS-IS-NOT-A-TIMESTAMP'
       ), 'exec-ref-4'
     ) $$,
  'a Meta retry of the same failed event_key does not raise - dedupe survived the earlier failure'
);

SELECT is(
  (SELECT count(*)::int FROM core.webhook_events WHERE provider='META' AND event_key='TEST:FAIL:1'),
  1,
  'still exactly one row after the retry - no duplicate processing attempt occurred'
);

-- =======================================================================
-- 4. CONCURRENCY MECHANISM: the actual guarantee both properties above
--    rely on is the UNIQUE index on (provider, event_key). Prove it is
--    still exactly what's enforced (two true concurrent connections racing
--    this same function are exercised separately by
--    supabase/tests/p0/002b_concurrency_check.sh, since real cross-
--    connection concurrency cannot be expressed inside one transaction).
-- =======================================================================
SELECT throws_ok(
  $$ INSERT INTO core.webhook_events(provider,event_key,event_type,payload) VALUES ('META','TEST:DUP:1','DELIVERY_STATUS','{}'::jsonb) $$,
  '23505',
  NULL,
  'the UNIQUE(provider,event_key) constraint - the real concurrency guarantee - is present and enforced'
);

SELECT * FROM finish();
ROLLBACK;
