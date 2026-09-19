-- ============================================================================
-- ML Automações — READ-ONLY contract introspection
-- ============================================================================
--
-- PURPOSE
--   Resolve every "UNVERIFIED" item from docs/AUDIT/PHASE_A.md (§I) and
--   supabase/migrations/MIGRATION_BASE_STATUS.md against the REAL database,
--   instead of guessing/reconstructing. This is the single introspection run
--   required by the approved P0 plan before P0.6 (missing contracts) and
--   before finalizing the P0.1 (migration 051) fix design.
--
-- SAFETY GUARANTEE
--   This script contains ONLY read-only statements: SELECT queries against
--   information_schema and pg_catalog. It does not, and must not, contain
--   CREATE, ALTER, DROP, INSERT, UPDATE, DELETE, TRUNCATE, GRANT, REVOKE, or
--   any function/procedure CALL that could mutate state. It is safe to run
--   against STAGING (or even PROD, though PROD access is out of scope for
--   this exercise) by any role with normal read privileges — no superuser
--   required, since pg_catalog/information_schema metadata is world-readable
--   in Postgres by default.
--
-- HOW TO RUN
--   Paste this whole file into the Supabase SQL editor (STAGING project) and
--   run it, OR: psql "$STAGING_DATABASE_URL" -f 00_readonly_contract_check.sql -o result.txt
--   Do NOT run this against PROD as part of this exercise; STAGING is the
--   target per the approved plan.
--
-- WHAT TO DO WITH THE OUTPUT
--   Each SELECT below is preceded by a banner query so the output is
--   self-labeling in any SQL client. Copy/paste or export the FULL output
--   (all sections) back — partial output (e.g. only the last section) is not
--   enough, because earlier sections are what let us catch things we didn't
--   think to ask about explicitly in the final checklist (Section 8).
-- ============================================================================


-- ============================================================================
-- SECTION 0 — Environment sanity
-- ============================================================================
SELECT '=== SECTION 0: ENVIRONMENT ===' AS section;

SELECT
  current_database()   AS database,
  current_user         AS connected_as,
  inet_server_addr()   AS server_addr,
  version()            AS postgres_version,
  now()                AS run_at;

SELECT '-- installed extensions --' AS note;
SELECT extname, extversion FROM pg_extension ORDER BY extname;


-- ============================================================================
-- SECTION 1 — Schema existence
-- ============================================================================
SELECT '=== SECTION 1: SCHEMAS ===' AS section;

SELECT schema_name
FROM information_schema.schemata
WHERE schema_name IN ('core','private','public','supabase_migrations')
ORDER BY schema_name;


-- ============================================================================
-- SECTION 2 — Every table referenced by migrations 043-057: exists? row count?
-- ============================================================================
SELECT '=== SECTION 2: TABLE INVENTORY (referenced by 043-057) ===' AS section;

WITH expected(schema_name, table_name) AS (
  VALUES
    ('core','ai_runtime_policies'), ('core','audit_log'), ('core','automation_incidents'),
    ('core','automation_policies'), ('core','business_ai_settings'), ('core','business_brand_profiles'),
    ('core','business_memberships'), ('core','business_settings'), ('core','businesses'),
    ('core','campaign_conversions'), ('core','campaign_recipients'), ('core','campaigns'),
    ('core','customer_marketing_preferences'), ('core','customer_preferences'), ('core','customers'),
    ('core','integration_job_attempts'), ('core','integration_jobs'), ('core','knowledge_documents'),
    ('core','marketing_consent_events'), ('core','media_assets'), ('core','message_delivery_events'),
    ('core','messages'), ('core','platform_admins'), ('core','platform_users'),
    ('core','product_categories'), ('core','products'), ('core','professional_services'),
    ('core','professionals'), ('core','services'), ('core','waitlist_subscriptions_v2'),
    ('core','webhook_events'), ('core','conversations'),
    -- Section I priority items (must exist for P0.6):
    ('core','appointment_calendar_syncs'), ('core','customer_engagement_profiles'),
    ('core','appointments'), ('core','appointment_items'), ('core','appointment_cancellations'),
    ('core','slot_offers'), ('core','slot_offer_options'),
    ('public','ml_user_businesses')
)
SELECT
  e.schema_name,
  e.table_name,
  (c.oid IS NOT NULL) AS exists,
  CASE WHEN c.oid IS NOT NULL THEN pg_catalog.pg_size_pretty(pg_total_relation_size(c.oid)) END AS size,
  (SELECT reltuples::bigint FROM pg_class WHERE oid = c.oid) AS approx_row_estimate
FROM expected e
LEFT JOIN pg_namespace n ON n.nspname = e.schema_name
LEFT JOIN pg_class c ON c.relname = e.table_name AND c.relnamespace = n.oid AND c.relkind IN ('r','p')
ORDER BY exists ASC, e.schema_name, e.table_name;


-- ============================================================================
-- SECTION 3 — FULL signature dump of every function in core/private/public
-- (this is the authoritative answer to "assinaturas reais de todas as
-- funções chamadas por 043-057" — every overload, every arg, every return
-- type, cross-referenced by hand against call sites afterward)
-- ============================================================================
SELECT '=== SECTION 3: FUNCTION/PROCEDURE SIGNATURES (core, private, public) ===' AS section;

SELECT
  n.nspname                                   AS schema,
  p.proname                                   AS function_name,
  pg_get_function_identity_arguments(p.oid)   AS identity_arguments,
  pg_get_function_arguments(p.oid)            AS full_arguments_with_defaults,
  pg_get_function_result(p.oid)               AS returns,
  CASE p.prokind WHEN 'f' THEN 'function' WHEN 'p' THEN 'procedure'
                 WHEN 'a' THEN 'aggregate' WHEN 'w' THEN 'window' END AS kind,
  p.prosecdef                                 AS security_definer,
  CASE p.provolatile WHEN 'i' THEN 'IMMUTABLE' WHEN 's' THEN 'STABLE' WHEN 'v' THEN 'VOLATILE' END AS volatility
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname IN ('core','private','public')
ORDER BY n.nspname, p.proname, identity_arguments;


-- ============================================================================
-- SECTION 4 — Full column definitions for tables of special interest
-- ============================================================================
SELECT '=== SECTION 4: COLUMN DEFINITIONS (tables of special interest) ===' AS section;

SELECT
  table_schema, table_name, ordinal_position, column_name, data_type,
  character_maximum_length, is_nullable, column_default
FROM information_schema.columns
WHERE table_schema = 'core'
  AND table_name IN (
    'businesses', 'business_settings', 'business_channels',
    'customers', 'customer_channels', 'customer_preferences', 'customer_engagement_profiles',
    'conversations', 'messages', 'message_delivery_events',
    'appointments', 'appointment_items', 'appointment_calendar_syncs', 'appointment_cancellations',
    'slot_offers', 'slot_offer_options',
    'integration_jobs', 'integration_job_attempts'
  )
ORDER BY table_name, ordinal_position;


-- ============================================================================
-- SECTION 5 — Constraints (PK / UNIQUE / FK / CHECK) for core schema,
-- with full definition text. This is what answers, concretely:
--   - does core.businesses have `business_code` and/or `code`?
--   - does core.messages have UNIQUE(business_id, id)?
--   - what is the REAL constraint set on core.message_delivery_events today?
--   - what does business_settings.rescheduling_* actually look like?
-- ============================================================================
SELECT '=== SECTION 5: CONSTRAINTS (core schema) ===' AS section;

SELECT
  tc.table_name,
  tc.constraint_name,
  tc.constraint_type,
  pg_get_constraintdef(pgc.oid) AS definition
FROM information_schema.table_constraints tc
JOIN pg_constraint pgc
  ON pgc.conname = tc.constraint_name
JOIN pg_namespace pgn ON pgn.oid = pgc.connamespace AND pgn.nspname = tc.table_schema
WHERE tc.table_schema = 'core'
ORDER BY tc.table_name, tc.constraint_type, tc.constraint_name;

SELECT '-- explicit spot-check: does core.messages have a composite unique on (business_id, id)? --' AS note;
SELECT
  conname, pg_get_constraintdef(oid) AS definition
FROM pg_constraint
WHERE conrelid = 'core.messages'::regclass
  AND contype IN ('u','p')
ORDER BY conname;

SELECT '-- explicit spot-check: core.businesses columns (code vs business_code) --' AS note;
SELECT column_name, data_type, is_nullable
FROM information_schema.columns
WHERE table_schema = 'core' AND table_name = 'businesses'
  AND column_name IN ('code','business_code')
ORDER BY column_name;


-- ============================================================================
-- SECTION 6 — Triggers in core schema (to confirm core.set_updated_at usage)
-- ============================================================================
SELECT '=== SECTION 6: TRIGGERS (core schema) ===' AS section;

SELECT
  event_object_table AS table_name,
  trigger_name,
  action_timing,
  string_agg(event_manipulation, ', ') AS events,
  action_statement
FROM information_schema.triggers
WHERE trigger_schema = 'core'
GROUP BY event_object_table, trigger_name, action_timing, action_statement
ORDER BY table_name, trigger_name;


-- ============================================================================
-- SECTION 7 — Migration tracking table, if one exists (best-effort, does not
-- error if absent — helps replace guesswork in MIGRATION_BASE_STATUS.md with
-- a real applied-migrations list if the project uses Supabase CLI migration
-- tracking or an equivalent custom table).
-- ============================================================================
SELECT '=== SECTION 7: MIGRATION TRACKING (best-effort) ===' AS section;

SELECT
  table_schema, table_name
FROM information_schema.tables
WHERE table_name ILIKE '%schema_migrations%'
   OR (table_schema = 'supabase_migrations');

-- If the query above found supabase_migrations.schema_migrations, also run:
-- SELECT version, name, statements IS NOT NULL AS has_statements
-- FROM supabase_migrations.schema_migrations ORDER BY version;
-- (left commented out because the table name/shape varies by project setup
-- and an unconditional SELECT here would error the whole script if absent)


-- ============================================================================
-- SECTION 8 — FINAL CHECKLIST: the 12 items from the approved P0 plan,
-- answered directly. Read this section first; use Sections 0-7 as evidence.
-- ============================================================================
SELECT '=== SECTION 8: FINAL CHECKLIST (read this first) ===' AS section;

SELECT '1. core.finalize_assistant_turn' AS item,
       EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
               WHERE n.nspname='core' AND p.proname='finalize_assistant_turn') AS found
UNION ALL
SELECT '2. core.select_and_confirm_slot_offer_option_v3',
       EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
               WHERE n.nspname='core' AND p.proname='select_and_confirm_slot_offer_option_v3')
UNION ALL
SELECT '3. core.appointment_calendar_syncs (table)',
       EXISTS (SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
               WHERE n.nspname='core' AND c.relname='appointment_calendar_syncs' AND c.relkind IN ('r','p'))
UNION ALL
SELECT '4. core.prepare_appointment_calendar_sync',
       EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
               WHERE n.nspname='core' AND p.proname='prepare_appointment_calendar_sync')
UNION ALL
SELECT '5. core.complete_appointment_calendar_sync',
       EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
               WHERE n.nspname='core' AND p.proname='complete_appointment_calendar_sync')
UNION ALL
SELECT '6. core.fail_appointment_calendar_sync',
       EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
               WHERE n.nspname='core' AND p.proname='fail_appointment_calendar_sync')
UNION ALL
SELECT '7. core.prepare_assistant_context',
       EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
               WHERE n.nspname='core' AND p.proname='prepare_assistant_context')
UNION ALL
SELECT '8. core.run_housekeeping_v2',
       EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
               WHERE n.nspname='core' AND p.proname='run_housekeeping_v2')
UNION ALL
SELECT '9. core.set_updated_at',
       EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
               WHERE n.nspname='core' AND p.proname='set_updated_at')
UNION ALL
SELECT '10. core.customer_preferences (table)',
       EXISTS (SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
               WHERE n.nspname='core' AND c.relname='customer_preferences' AND c.relkind IN ('r','p'))
UNION ALL
SELECT '11. core.customer_engagement_profiles (table)',
       EXISTS (SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
               WHERE n.nspname='core' AND c.relname='customer_engagement_profiles' AND c.relkind IN ('r','p'))
UNION ALL
SELECT '12. business_settings.rescheduling_enabled (column)',
       EXISTS (SELECT 1 FROM information_schema.columns
               WHERE table_schema='core' AND table_name='business_settings' AND column_name='rescheduling_enabled')
UNION ALL
SELECT '13. business_settings.rescheduling_notice_minutes (column)',
       EXISTS (SELECT 1 FROM information_schema.columns
               WHERE table_schema='core' AND table_name='business_settings' AND column_name='rescheduling_notice_minutes')
UNION ALL
SELECT '14. UNIQUE(business_id, id) on core.messages',
       EXISTS (
         SELECT 1 FROM pg_constraint
         WHERE conrelid = 'core.messages'::regclass AND contype IN ('u','p')
           AND (SELECT array_agg(attname ORDER BY attname)
                FROM unnest(conkey) WITH ORDINALITY AS k(attnum, ord)
                JOIN pg_attribute a ON a.attrelid = 'core.messages'::regclass AND a.attnum = k.attnum
               ) @> ARRAY['business_id','id']::name[]
       )
UNION ALL
SELECT '15. core.businesses.business_code (column, expected canonical name)',
       EXISTS (SELECT 1 FROM information_schema.columns
               WHERE table_schema='core' AND table_name='businesses' AND column_name='business_code')
UNION ALL
SELECT '16. core.businesses.code (column, the buggy name migration 048 originally used)',
       EXISTS (SELECT 1 FROM information_schema.columns
               WHERE table_schema='core' AND table_name='businesses' AND column_name='code')
UNION ALL
SELECT '17. core.select_and_confirm_slot_offer_option (non-v3, from migration 026, for comparison)',
       EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
               WHERE n.nspname='core' AND p.proname='select_and_confirm_slot_offer_option')
UNION ALL
SELECT '18. core.leave_waitlist (non-v2, referenced defensively in 054)',
       EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
               WHERE n.nspname='core' AND p.proname='leave_waitlist')
ORDER BY 1;

-- ============================================================================
-- END OF SCRIPT — no mutation statements above this line.
-- ============================================================================
