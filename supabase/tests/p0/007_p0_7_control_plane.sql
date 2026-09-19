-- P0.7 — core.execute_control_plane_action_final is now the single
-- canonical control-plane entry point (see migration 055's header comment
-- and docs/AUDIT/PHASE_A.md D.4). This proves: per-action RBAC allowlists
-- are enforced correctly per role, a real write action succeeds, a real
-- read action succeeds, delegation to core.execute_control_plane_action_v2
-- (kept as an internal helper) still works, and the exact call shape
-- apps/ml-console/src/lib/supabase.ts's control() helper and
-- supabase/functions/control-api/index.ts use succeeds end-to-end.

CREATE EXTENSION IF NOT EXISTS pgtap;

BEGIN;

SELECT plan(12);

INSERT INTO core.businesses (id, business_code, name)
VALUES ('00000000-0000-0000-0000-0000000007a1', 'BIZ_P07', 'Business P0.7');
INSERT INTO core.business_settings (business_id) VALUES ('00000000-0000-0000-0000-0000000007a1');
INSERT INTO core.business_brand_profiles (business_id) VALUES ('00000000-0000-0000-0000-0000000007a1');
INSERT INTO core.business_ai_settings (business_id) VALUES ('00000000-0000-0000-0000-0000000007a1');

INSERT INTO core.business_memberships (id, business_id, user_id, role, active) VALUES
  (gen_random_uuid(), '00000000-0000-0000-0000-0000000007a1', '00000000-0000-0000-0000-0000000007b1', 'MANAGER', true),
  (gen_random_uuid(), '00000000-0000-0000-0000-0000000007a1', '00000000-0000-0000-0000-0000000007b2', 'VIEWER', true),
  (gen_random_uuid(), '00000000-0000-0000-0000-0000000007a1', '00000000-0000-0000-0000-0000000007b3', 'EMPLOYEE', true);

-- =======================================================================
-- 1. RBAC: MANAGER can UPSERT_PRODUCT (allowed by authorize_action_v2).
-- =======================================================================
SELECT core.execute_control_plane_action_final(
  '00000000-0000-0000-0000-0000000007b1'::uuid, '00000000-0000-0000-0000-0000000007a1'::uuid,
  'UPSERT_PRODUCT', jsonb_build_object('sku','SKU-1','name','Produto Teste','price',19.9),
  gen_random_uuid()::text, 'exec-p07-1'
) AS manager_upsert \gset

SELECT is((:'manager_upsert'::jsonb->>'code'), 'PRODUCT_UPSERTED', 'MANAGER can UPSERT_PRODUCT (allowlisted action)');

SELECT is(
  (SELECT count(*)::int FROM core.products WHERE business_id = '00000000-0000-0000-0000-0000000007a1'::uuid),
  1,
  'the product was actually persisted'
);

-- =======================================================================
-- 2. RBAC: VIEWER cannot UPSERT_PRODUCT (not in VIEWER's allowlist).
-- =======================================================================
SELECT core.execute_control_plane_action_final(
  '00000000-0000-0000-0000-0000000007b2'::uuid, '00000000-0000-0000-0000-0000000007a1'::uuid,
  'UPSERT_PRODUCT', jsonb_build_object('sku','SKU-2','name','Produto Proibido'),
  gen_random_uuid()::text, 'exec-p07-2'
) AS viewer_upsert \gset

SELECT is((:'viewer_upsert'::jsonb->>'code'), 'FORBIDDEN', 'VIEWER is correctly forbidden from UPSERT_PRODUCT');

-- =======================================================================
-- 3. RBAC: EMPLOYEE cannot LIST_CUSTOMERS (not in EMPLOYEE's allowlist -
--    EMPLOYEE only gets GET_DASHBOARD/LIST_MY_APPOINTMENTS/LIST_SERVICES/
--    LIST_PRODUCTS/GET_SETTINGS).
-- =======================================================================
SELECT core.execute_control_plane_action_final(
  '00000000-0000-0000-0000-0000000007b3'::uuid, '00000000-0000-0000-0000-0000000007a1'::uuid,
  'LIST_CUSTOMERS', '{}'::jsonb, gen_random_uuid()::text, 'exec-p07-3'
) AS employee_list_customers \gset

SELECT is((:'employee_list_customers'::jsonb->>'code'), 'FORBIDDEN', 'EMPLOYEE is correctly forbidden from LIST_CUSTOMERS');

-- EMPLOYEE *can* read products, which IS in their allowlist.
SELECT core.execute_control_plane_action_final(
  '00000000-0000-0000-0000-0000000007b3'::uuid, '00000000-0000-0000-0000-0000000007a1'::uuid,
  'LIST_PRODUCTS', '{}'::jsonb, gen_random_uuid()::text, 'exec-p07-4'
) AS employee_list_products \gset

SELECT ok((:'employee_list_products'::jsonb->>'ok')::boolean, 'EMPLOYEE can LIST_PRODUCTS (allowlisted read action)');

-- =======================================================================
-- 4. Read action (GET_SETTINGS) returns the expected shape.
-- =======================================================================
SELECT core.execute_control_plane_action_final(
  '00000000-0000-0000-0000-0000000007b1'::uuid, '00000000-0000-0000-0000-0000000007a1'::uuid,
  'GET_SETTINGS', '{}'::jsonb, gen_random_uuid()::text, 'exec-p07-5'
) AS get_settings \gset

SELECT ok(
  (:'get_settings'::jsonb ? 'business') AND (:'get_settings'::jsonb ? 'settings') AND (:'get_settings'::jsonb ? 'brand') AND (:'get_settings'::jsonb ? 'ai'),
  'GET_SETTINGS returns business/settings/brand/ai as expected'
);

-- =======================================================================
-- 5. Delegation to _v2 (CREATE_CAMPAIGN) still works - _v2 is kept as an
--    internal helper, not an independent entry point.
-- =======================================================================
SELECT core.execute_control_plane_action_final(
  '00000000-0000-0000-0000-0000000007b1'::uuid, '00000000-0000-0000-0000-0000000007a1'::uuid,
  'CREATE_CAMPAIGN', jsonb_build_object('name','Campanha Teste','status','DRAFT'),
  gen_random_uuid()::text, 'exec-p07-6'
) AS create_campaign \gset

SELECT is((:'create_campaign'::jsonb->>'code'), 'CAMPAIGN_CREATED', 'CREATE_CAMPAIGN (delegated internally to _v2) still works via _final');

SELECT is(
  (SELECT count(*)::int FROM core.campaigns WHERE business_id = '00000000-0000-0000-0000-0000000007a1'::uuid),
  1,
  'the campaign was actually persisted through the delegated call'
);

-- =======================================================================
-- 6. Idempotency key is still required.
-- =======================================================================
SELECT is(
  (core.execute_control_plane_action_final(
    '00000000-0000-0000-0000-0000000007b1'::uuid, '00000000-0000-0000-0000-0000000007a1'::uuid,
    'UPSERT_PRODUCT', jsonb_build_object('sku','SKU-3','name','X'), NULL, 'exec-p07-7'
  )->>'code'),
  'IDEMPOTENCY_KEY_REQUIRED',
  'a missing idempotency_key is still rejected'
);

-- =======================================================================
-- 7. The exact 6-named-parameter shape the frontend/Edge Function/n8n use.
-- =======================================================================
-- (GET_DASHBOARD is not used here even though it's a valid action: it
-- queries core.appointments, which this harness's minimal messaging-focused
-- fixture intentionally does not build - see run_local_harness.sh's note.
-- GET_SETTINGS already proved the read path in test #6; this test is only
-- about the named-parameter call shape itself.)
SELECT lives_ok(
  $$ SELECT core.execute_control_plane_action_final(
       p_actor_user_id := '00000000-0000-0000-0000-0000000007b1'::uuid,
       p_business_id := '00000000-0000-0000-0000-0000000007a1'::uuid,
       p_action := 'GET_SETTINGS',
       p_arguments := '{}'::jsonb,
       p_idempotency_key := gen_random_uuid()::text,
       p_execution_ref := 'exec-p07-8'
     ) $$,
  'the exact named-parameter call shape control-api/index.ts and n8n/08_ml_control_plane.json use succeeds'
);

-- =======================================================================
-- 8. TEST_MATRIX.md #13 (tenant isolation): a real member of business A
--    must be completely unable to act on or read business B's data
--    through the control plane, even for actions they're normally
--    allowed to perform.
-- =======================================================================
INSERT INTO core.businesses (id, business_code, name)
VALUES ('00000000-0000-0000-0000-0000000007a2', 'BIZ_P07_B', 'Business P0.7 (other tenant)');
INSERT INTO core.business_settings (business_id) VALUES ('00000000-0000-0000-0000-0000000007a2');
INSERT INTO core.business_brand_profiles (business_id) VALUES ('00000000-0000-0000-0000-0000000007a2');
INSERT INTO core.business_ai_settings (business_id) VALUES ('00000000-0000-0000-0000-0000000007a2');

SELECT is(
  (core.execute_control_plane_action_final(
    '00000000-0000-0000-0000-0000000007b1'::uuid,  -- business A's MANAGER
    '00000000-0000-0000-0000-0000000007a2'::uuid,  -- business B
    'UPSERT_PRODUCT', jsonb_build_object('sku','SKU-CROSS','name','Should Not Exist'),
    gen_random_uuid()::text, 'exec-p07-9'
  )->>'code'),
  'FORBIDDEN',
  'a MANAGER of business A gets FORBIDDEN when acting on business B - no membership there at all'
);

SELECT is(
  (SELECT count(*)::int FROM core.products WHERE business_id = '00000000-0000-0000-0000-0000000007a2'::uuid),
  0,
  'nothing was written to business B as a result of the cross-tenant attempt'
);

SELECT * FROM finish();
ROLLBACK;
