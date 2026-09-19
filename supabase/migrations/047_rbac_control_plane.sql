
-- 047_rbac_control_plane.sql
CREATE TABLE IF NOT EXISTS core.platform_users(
 user_id UUID PRIMARY KEY,display_name TEXT,created_at TIMESTAMPTZ NOT NULL DEFAULT now());
CREATE TABLE IF NOT EXISTS core.business_memberships(
 id UUID PRIMARY KEY DEFAULT gen_random_uuid(),business_id UUID NOT NULL,user_id UUID NOT NULL,
 role TEXT NOT NULL CHECK(role IN('OWNER','MANAGER','RECEPTIONIST','EMPLOYEE','VIEWER')),
 active BOOLEAN NOT NULL DEFAULT true,created_at TIMESTAMPTZ NOT NULL DEFAULT now(),updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
 UNIQUE(business_id,user_id));
CREATE TABLE IF NOT EXISTS core.platform_admins(
 user_id UUID PRIMARY KEY,active BOOLEAN NOT NULL DEFAULT true,created_at TIMESTAMPTZ NOT NULL DEFAULT now());
CREATE TABLE IF NOT EXISTS core.audit_log(
 id BIGSERIAL PRIMARY KEY,business_id UUID,actor_user_id UUID,actor_type TEXT NOT NULL,
 action TEXT NOT NULL,entity_type TEXT,entity_id TEXT,request_id TEXT,payload JSONB NOT NULL DEFAULT '{}'::jsonb,
 created_at TIMESTAMPTZ NOT NULL DEFAULT now());

CREATE OR REPLACE FUNCTION private.user_role_for_business(p_user UUID,p_business UUID)
RETURNS TEXT LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
 SELECT CASE
  WHEN EXISTS(SELECT 1 FROM core.platform_admins a WHERE a.user_id=p_user AND a.active) THEN 'PLATFORM_ADMIN'
  ELSE (SELECT m.role FROM core.business_memberships m WHERE m.user_id=p_user AND m.business_id=p_business AND m.active LIMIT 1)
 END $$;
REVOKE ALL ON FUNCTION private.user_role_for_business(UUID,UUID) FROM PUBLIC;

CREATE OR REPLACE FUNCTION core.authorize_action_v1(p_user UUID,p_business UUID,p_action TEXT)
RETURNS BOOLEAN LANGUAGE plpgsql STABLE AS $$
DECLARE r text;
BEGIN
 r:=private.user_role_for_business(p_user,p_business);
 IF r='PLATFORM_ADMIN' THEN RETURN true; END IF;
 IF r='OWNER' THEN RETURN true; END IF;
 IF r='MANAGER' THEN RETURN upper(p_action) NOT IN('DELETE_BUSINESS','TRANSFER_OWNERSHIP'); END IF;
 IF r='RECEPTIONIST' THEN RETURN upper(p_action) IN('LIST_APPOINTMENTS','CREATE_APPOINTMENT','CANCEL_APPOINTMENT','RESCHEDULE_APPOINTMENT','GET_CUSTOMER','UPDATE_CUSTOMER','JOIN_WAITLIST'); END IF;
 IF r='EMPLOYEE' THEN RETURN upper(p_action) IN('LIST_MY_APPOINTMENTS','SET_MY_AVAILABILITY','CHECK_IN','COMPLETE_APPOINTMENT'); END IF;
 IF r='VIEWER' THEN RETURN upper(p_action) LIKE 'GET_%' OR upper(p_action) LIKE 'LIST_%'; END IF;
 RETURN false;
END $$;

CREATE OR REPLACE FUNCTION core.execute_control_plane_action_v2(
 p_actor_user_id UUID,p_business_id UUID,p_action TEXT,p_arguments JSONB,p_idempotency_key TEXT,p_execution_ref TEXT
) RETURNS JSONB LANGUAGE plpgsql AS $$
DECLARE a text:=upper(coalesce(p_action,'')); result jsonb;
BEGIN
 IF NOT core.authorize_action_v1(p_actor_user_id,p_business_id,a) THEN
  RETURN jsonb_build_object('ok',false,'code','FORBIDDEN');
 END IF;
 IF nullif(btrim(p_idempotency_key),'') IS NULL THEN RETURN jsonb_build_object('ok',false,'code','IDEMPOTENCY_KEY_REQUIRED'); END IF;

 IF a='SET_MARKETING_CONSENT' THEN
  result:=core.set_marketing_consent_v1(p_business_id,(p_arguments->>'customer_id')::uuid,(p_arguments->>'marketing_opt_in')::boolean,'CONTROL_PLANE');
 ELSIF a='UPSERT_PRODUCT' THEN
  INSERT INTO core.products(id,business_id,sku,name,description,price,currency,stock_status,active,tags,attributes)
  VALUES(coalesce(nullif(p_arguments->>'id','')::uuid,gen_random_uuid()),p_business_id,p_arguments->>'sku',p_arguments->>'name',
    p_arguments->>'description',nullif(p_arguments->>'price','')::numeric,coalesce(p_arguments->>'currency','BRL'),
    coalesce(p_arguments->>'stock_status','UNKNOWN'),coalesce((p_arguments->>'active')::boolean,true),
    coalesce(ARRAY(SELECT jsonb_array_elements_text(p_arguments->'tags')),'{}'::text[]),coalesce(p_arguments->'attributes','{}'::jsonb))
  ON CONFLICT(business_id,sku) DO UPDATE SET name=excluded.name,description=excluded.description,price=excluded.price,
    currency=excluded.currency,stock_status=excluded.stock_status,active=excluded.active,tags=excluded.tags,attributes=excluded.attributes,updated_at=now();
  result:=jsonb_build_object('ok',true,'code','PRODUCT_UPSERTED');
 ELSIF a='CREATE_CAMPAIGN' THEN
  INSERT INTO core.campaigns(business_id,name,status,objective,audience_rules,content,scheduled_at,starts_at,ends_at,created_by)
  VALUES(p_business_id,p_arguments->>'name',coalesce(p_arguments->>'status','DRAFT'),p_arguments->>'objective',
   coalesce(p_arguments->'audience_rules','{}'::jsonb),coalesce(p_arguments->'content','{}'::jsonb),
   nullif(p_arguments->>'scheduled_at','')::timestamptz,nullif(p_arguments->>'starts_at','')::timestamptz,
   nullif(p_arguments->>'ends_at','')::timestamptz,p_actor_user_id)
  RETURNING jsonb_build_object('ok',true,'code','CAMPAIGN_CREATED','campaign_id',id) INTO result;
 ELSE
  result:=jsonb_build_object('ok',false,'code','ACTION_NOT_AVAILABLE_IN_CONTROL_PLANE','action',a);
 END IF;

 INSERT INTO core.audit_log(business_id,actor_user_id,actor_type,action,request_id,payload)
 VALUES(p_business_id,p_actor_user_id,'USER',a,p_execution_ref,jsonb_build_object('arguments',p_arguments,'result',result));
 RETURN result;
END $$;
