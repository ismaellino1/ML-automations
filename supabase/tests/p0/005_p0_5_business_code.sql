-- P0.5 — core.ingest_whatsapp_event_v1 must resolve the business by its
-- real business_code column, not the nonexistent "code" column, for every
-- inbound WhatsApp message (the hot path this bug sat in).
--
-- core.prepare_assistant_turn's real source is not part of this handoff
-- package (see docs/AUDIT/PHASE_A.md D.3/Section I - it is confirmed to
-- exist and be called correctly elsewhere, but its own implementation is
-- UNVERIFIED pending STAGING introspection). Reconstructing its real
-- behavior would be exactly the "guessing" the approved P0 plan forbids.
-- So this test uses a narrow, explicitly-labeled TEST DOUBLE for it - with
-- its known-real signature (see 01_KNOWN_DATABASE_FACTS.md and preflight's
-- BASE_001_042_CONTRACT.sql, which checks this exact 11-arg signature) -
-- that does nothing but record which business_code it was called with.
-- That isolates and proves the ONE thing P0.5 actually changed: whether
-- ingest_whatsapp_event_v1 extracts business_code (not code) before calling
-- it. It makes no claim about prepare_assistant_turn's real internal
-- behavior. Being a CREATE FUNCTION, it is transactional and is undone by
-- this test's own ROLLBACK - it never touches the real schema.

CREATE EXTENSION IF NOT EXISTS pgtap;

BEGIN;

SELECT plan(3);

CREATE TEMP TABLE test_prepare_turn_calls (business_code text) ON COMMIT DROP;

CREATE OR REPLACE FUNCTION core.prepare_assistant_turn(
  p_business_code text, p_channel_type text, p_provider text, p_external_user_id text,
  p_idempotency_key text, p_external_message_id text, p_message_type text, p_text_content text,
  p_raw_payload jsonb DEFAULT '{}'::jsonb, p_provider_timestamp timestamptz DEFAULT null,
  p_recent_messages_limit int DEFAULT 12
) RETURNS JSONB LANGUAGE plpgsql AS $stub$
BEGIN
  INSERT INTO test_prepare_turn_calls(business_code) VALUES (p_business_code);
  RETURN jsonb_build_object('turn', jsonb_build_object('should_process', false, 'message_id', gen_random_uuid()));
END;
$stub$;

INSERT INTO core.businesses (id, business_code, name)
VALUES ('00000000-0000-0000-0000-0000000005a1', 'BIZ_P05', 'Business P0.5');
INSERT INTO core.business_channels (id, business_id, channel_type, provider, external_channel_id, status)
VALUES ('00000000-0000-0000-0000-0000000005c1', '00000000-0000-0000-0000-0000000005a1', 'WHATSAPP', 'META', 'PHONE_P05', 'ACTIVE');

-- The regression this test exists for: before the fix, this call raised
-- `column "code" does not exist` (undefined_column) for every single
-- inbound WhatsApp message, because core.businesses has no such column.
SELECT lives_ok(
  $$ SELECT core.ingest_whatsapp_event_v1(
       'PHONE_P05','WHATSAPP','META','5511900000123','Cliente Teste',
       'IN:META:wamid.P05.1','wamid.P05.1','text',
       '{}'::jsonb,'{}'::jsonb,
       jsonb_build_object('text','Olá, quero agendar um horário','raw_payload','{}'::jsonb),
       now(),'exec-p05-1'
     ) $$,
  'inbound WhatsApp event ingestion no longer errors on the businesses.code/business_code mismatch'
);

SELECT is(
  (SELECT business_code FROM test_prepare_turn_calls LIMIT 1),
  'BIZ_P05',
  'the correct business_code value (from the real business_code column) reaches prepare_assistant_turn'
);

SELECT is(
  (SELECT count(*)::int FROM test_prepare_turn_calls),
  1,
  'prepare_assistant_turn was invoked exactly once for this event'
);

SELECT * FROM finish();
ROLLBACK;
