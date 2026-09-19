-- P0.8 — TEST_MATRIX.md scenarios covered here:
--   #7 promotion (campaign) opt-out and frequency cap are respected.
--   #6 (partial) media processing job mechanics: claim -> complete triggers
--      a follow-up conversation job; claim -> fail schedules a retry.
--      (The actual AI transcription/vision quality across audio/image/
--      document/video/corrupted-media is an external-provider behavior
--      question, not something this local harness can exercise - see
--      docs/P0_TEST_MATRIX_COVERAGE.md.)

CREATE EXTENSION IF NOT EXISTS pgtap;

BEGIN;

SELECT plan(8);

INSERT INTO core.businesses (id, business_code, name)
VALUES ('00000000-0000-0000-0000-0000000009b1', 'BIZ_P08B', 'Business P0.8b');

-- =======================================================================
-- #7 — campaign audience respects marketing opt-out and frequency cap.
-- =======================================================================
INSERT INTO core.customers (id, business_id, name) VALUES
  ('00000000-0000-0000-0000-0000000009c1', '00000000-0000-0000-0000-0000000009b1', 'Opted In Customer'),
  ('00000000-0000-0000-0000-0000000009c2', '00000000-0000-0000-0000-0000000009b1', 'Opted Out Customer'),
  ('00000000-0000-0000-0000-0000000009c3', '00000000-0000-0000-0000-0000000009b1', 'Recently Contacted Customer');

INSERT INTO core.customer_preferences (business_id, customer_id, marketing_opt_in) VALUES
  ('00000000-0000-0000-0000-0000000009b1', '00000000-0000-0000-0000-0000000009c1', true),
  ('00000000-0000-0000-0000-0000000009b1', '00000000-0000-0000-0000-0000000009c2', false),
  ('00000000-0000-0000-0000-0000000009b1', '00000000-0000-0000-0000-0000000009c3', true);

INSERT INTO core.campaigns (id, business_id, name, status, scheduled_at, frequency_cap_days)
VALUES ('00000000-0000-0000-0000-0000000009d1', '00000000-0000-0000-0000-0000000009b1', 'Promo Teste', 'SCHEDULED', now() - interval '1 minute', 7);

-- Simulate a campaign this same customer was already sent 2 days ago
-- (inside the 7-day frequency cap window), for a DIFFERENT campaign.
INSERT INTO core.campaigns (id, business_id, name, status, frequency_cap_days)
VALUES ('00000000-0000-0000-0000-0000000009d0', '00000000-0000-0000-0000-0000000009b1', 'Campanha Anterior', 'COMPLETED', 7);
INSERT INTO core.campaign_recipients (campaign_id, business_id, customer_id, status, sent_at)
VALUES ('00000000-0000-0000-0000-0000000009d0', '00000000-0000-0000-0000-0000000009b1', '00000000-0000-0000-0000-0000000009c3', 'SENT', now() - interval '2 days');

SELECT core.enqueue_due_campaign_jobs(10, 'exec-p08b-1');
SELECT core.materialize_due_campaign_recipients(10, 'exec-p08b-2');

SELECT is(
  (SELECT status FROM core.campaign_recipients WHERE campaign_id = '00000000-0000-0000-0000-0000000009d1' AND customer_id = '00000000-0000-0000-0000-0000000009c1'),
  'ELIGIBLE',
  'the opted-in, never-contacted customer is ELIGIBLE'
);

SELECT is(
  (SELECT status FROM core.campaign_recipients WHERE campaign_id = '00000000-0000-0000-0000-0000000009d1' AND customer_id = '00000000-0000-0000-0000-0000000009c2'),
  'SUPPRESSED',
  'the opted-out customer is SUPPRESSED, never sent to'
);

SELECT is(
  (SELECT suppression_reason FROM core.campaign_recipients WHERE campaign_id = '00000000-0000-0000-0000-0000000009d1' AND customer_id = '00000000-0000-0000-0000-0000000009c2'),
  'MARKETING_OPT_OUT',
  'the suppression reason correctly identifies the opt-out'
);

SELECT is(
  (SELECT status FROM core.campaign_recipients WHERE campaign_id = '00000000-0000-0000-0000-0000000009d1' AND customer_id = '00000000-0000-0000-0000-0000000009c3'),
  'SUPPRESSED',
  'the recently-contacted customer is SUPPRESSED by the frequency cap, despite being opted in'
);

SELECT is(
  (SELECT suppression_reason FROM core.campaign_recipients WHERE campaign_id = '00000000-0000-0000-0000-0000000009d1' AND customer_id = '00000000-0000-0000-0000-0000000009c3'),
  'FREQUENCY_CAP',
  'the suppression reason correctly identifies the frequency cap'
);

-- =======================================================================
-- #6 (mechanics) — media job: claim -> complete triggers a follow-up
-- CONVERSATION_TURN job; claim -> fail schedules a retry via the same
-- (P0.4-fixed) job-queue primitives.
-- =======================================================================
INSERT INTO core.media_assets (id, business_id, media_id, mime_type, processing_status)
VALUES ('00000000-0000-0000-0000-0000000009e1', '00000000-0000-0000-0000-0000000009b1', 'MEDIA-1', 'audio/ogg', 'PENDING');

SELECT core.enqueue_integration_job_v1(
  '00000000-0000-0000-0000-0000000009b1'::uuid, 'MEDIA_PROCESS'::text, 'PROCESS'::text,
  jsonb_build_object(
    'media_asset_id','00000000-0000-0000-0000-0000000009e1',
    'media_id','MEDIA-1','media_type','audio','mime_type','audio/ogg',
    'message_id','00000000-0000-0000-0000-0000000009f1',
    'conversation_payload','{}'::jsonb
  )
) AS media_job_id \gset

SELECT core.claim_media_processing_batch(1, 'media-worker-1');
SELECT core.complete_media_processing_job(
  :'media_job_id'::uuid,
  jsonb_build_object('transcript','Olá, quero agendar um horário','summary','Pedido de agendamento','confidence',0.95)
);

SELECT is(
  (SELECT processing_status FROM core.media_assets WHERE id = '00000000-0000-0000-0000-0000000009e1'),
  'READY',
  'the media asset transitions to READY with its transcript recorded'
);

SELECT is(
  (SELECT count(*)::int FROM core.integration_jobs WHERE business_id = '00000000-0000-0000-0000-0000000009b1'::uuid AND job_type = 'CONVERSATION_TURN'),
  1,
  'completing the media job automatically enqueues the follow-up CONVERSATION_TURN job'
);

-- A second media job that genuinely fails goes through the same retry
-- mechanics already proven in 008 - just confirming the media-specific
-- wrapper (fail_media_processing_job) reaches the same underlying path.
SELECT core.enqueue_integration_job_v1(
  '00000000-0000-0000-0000-0000000009b1'::uuid, 'MEDIA_PROCESS'::text, 'PROCESS'::text,
  jsonb_build_object('media_asset_id','00000000-0000-0000-0000-0000000009e1','media_id','MEDIA-2'),
  NULL::text,NULL::text,NULL::uuid,100,3
) AS media_job_id_2 \gset

SELECT core.claim_media_processing_batch(1, 'media-worker-1');
SELECT core.fail_media_processing_job(:'media_job_id_2'::uuid, 'OpenAI transcription timeout', '{}'::jsonb);

SELECT is(
  (SELECT status FROM core.integration_jobs WHERE id = :'media_job_id_2'::uuid),
  'RETRY',
  'a failed media processing attempt (e.g. provider timeout) is retried, not silently dropped'
);

SELECT * FROM finish();
ROLLBACK;
