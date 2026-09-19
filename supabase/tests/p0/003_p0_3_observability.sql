-- P0.3 — core.record_automation_incident_v1 must be callable with exactly
-- the argument shape n8n/99_ml_observability.json now sends (8 positional
-- args: business_id, severity, workflow, execution_id, node, error_code,
-- error_message, context), and must produce an incident with enough data
-- to investigate for each real failure class the observability workflow is
-- meant to catch (Meta/Calendar/SQL/LLM/generic workflow errors).

CREATE EXTENSION IF NOT EXISTS pgtap;

BEGIN;

SELECT plan(11);

INSERT INTO core.businesses (id, business_code, name)
VALUES ('00000000-0000-0000-0000-0000000003a1', 'BIZ_P03', 'Business P0.3');

-- ---------------------------------------------------------------------
-- Sanity: the exact 8-arg call the fixed n8n node performs must succeed.
-- This is the direct regression test for D.5 - the old node called with
-- a single JSONB argument, which does not match this signature at all.
-- ---------------------------------------------------------------------
SELECT lives_ok(
  $$ SELECT core.record_automation_incident_v1(
       NULL::uuid,'ERROR','01 - ML INBOUND GATEWAY','exec-1','03 - ASSERT INGEST',
       'INGEST_FAILED','INGEST_FAILED:BUSINESS_CHANNEL_NOT_FOUND','{"raw":"..."}'::jsonb
     ) $$,
  'the exact positional call shape the fixed n8n workflow 99 now sends succeeds'
);

-- =======================================================================
-- Five representative failure classes, each proving a real incident row
-- is created with enough data for investigation.
-- =======================================================================

-- 1. Meta (WhatsApp Graph API) error
SELECT core.record_automation_incident_v1(
  '00000000-0000-0000-0000-0000000003a1'::uuid,'ERROR','04 - ML WHATSAPP DELIVERY','exec-meta-1','12 - ENVIAR WHATSAPP META',
  'META_GRAPH_API_ERROR','HTTP 401 from graph.facebook.com: access token expired',
  '{"http_status":401,"provider":"META"}'::jsonb
) AS meta_incident \gset

SELECT ok((:'meta_incident'::jsonb->>'ok')::boolean, 'Meta error produces ok:true');
SELECT isnt((:'meta_incident'::jsonb->>'incident_id'), NULL, 'Meta error produces a real incident_id');

-- 2. Google Calendar error
SELECT core.record_automation_incident_v1(
  '00000000-0000-0000-0000-0000000003a1'::uuid,'ERROR','05 - ML GOOGLE CALENDAR','exec-cal-1','16 - GOOGLE CALENDAR CREATE EVENT',
  'CALENDAR_API_ERROR','HTTP 503 from Google Calendar API: temporarily unavailable',
  '{"http_status":503,"provider":"GOOGLE_CALENDAR"}'::jsonb
) AS calendar_incident \gset

SELECT ok((:'calendar_incident'::jsonb->>'ok')::boolean, 'Calendar error produces ok:true');

-- 3. SQL error (e.g. a constraint violation surfaced from a worker)
SELECT core.record_automation_incident_v1(
  '00000000-0000-0000-0000-0000000003a1'::uuid,'ERROR','03 - ML CONVERSATION WORKER','exec-sql-1','core.finalize_conversation_job_final',
  '23505','duplicate key value violates unique constraint "uq_messages_idempotency"',
  '{"sqlstate":"23505"}'::jsonb
) AS sql_incident \gset

SELECT ok((:'sql_incident'::jsonb->>'ok')::boolean, 'SQL error produces ok:true');

-- 4. LLM / AI schema violation
SELECT core.record_automation_incident_v1(
  '00000000-0000-0000-0000-0000000003a1'::uuid,'WARNING','03 - ML CONVERSATION WORKER','exec-llm-1','02C - IA ORQUESTRADORA',
  'AI_SCHEMA_VIOLATION','orchestrator output failed json_schema validation: missing required field "action"',
  '{"model":"gpt-5.6-luna"}'::jsonb
) AS llm_incident \gset

SELECT ok((:'llm_incident'::jsonb->>'ok')::boolean, 'LLM schema-violation error produces ok:true');

-- 5. Generic/unclassified workflow error (the actual n8n Error Trigger
--    shape when nothing more specific is known - proves the fallback
--    error_code still results in a usable incident).
SELECT core.record_automation_incident_v1(
  NULL::uuid,'ERROR','07 - ML AUTOMATION SCHEDULER','exec-generic-1','11 - HOUSEKEEPING',
  'N8N_WORKFLOW_ERROR','function core.run_housekeeping_v2(integer, text) does not exist',
  '{"mode":"trigger"}'::jsonb
) AS generic_incident \gset

SELECT ok((:'generic_incident'::jsonb->>'ok')::boolean, 'generic/unclassified workflow error still produces ok:true');

-- ---------------------------------------------------------------------
-- Investigability: every incident above must be queryable with enough
-- context to answer "what happened, when, in which component, why".
-- ---------------------------------------------------------------------
SELECT is(
  (SELECT count(*)::int FROM core.automation_incidents WHERE business_id = '00000000-0000-0000-0000-0000000003a1'::uuid),
  4,
  'the 4 tenant-attributable incidents (Meta, Calendar, SQL, LLM) are all recorded under the right business_id'
);

SELECT is(
  (SELECT count(*)::int FROM core.automation_incidents WHERE business_id IS NULL AND workflow = '07 - ML AUTOMATION SCHEDULER'),
  1,
  'the tenant-less generic workflow error is still recorded (business_id NULL, not dropped)'
);

SELECT ok(
  (SELECT error_message FROM core.automation_incidents WHERE error_code = 'META_GRAPH_API_ERROR') LIKE '%401%',
  'the Meta incident preserves the real HTTP status in its error_message for investigation'
);

SELECT ok(
  (SELECT context->>'sqlstate' FROM core.automation_incidents WHERE error_code = '23505') = '23505',
  'the SQL incident preserves the SQLSTATE in its context for investigation'
);

SELECT * FROM finish();
ROLLBACK;
