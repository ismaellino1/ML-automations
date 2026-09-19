
-- 050_security_rls.sql
-- New UI-facing tables use Supabase Auth/RLS. Core operational tables remain server-side.
CREATE TABLE IF NOT EXISTS public.ml_user_businesses(
 business_id UUID NOT NULL,user_id UUID NOT NULL,role TEXT NOT NULL,active BOOLEAN NOT NULL DEFAULT true,
 PRIMARY KEY(business_id,user_id));
ALTER TABLE public.ml_user_businesses ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.ml_user_businesses FROM anon;
GRANT SELECT ON public.ml_user_businesses TO authenticated;
DROP POLICY IF EXISTS ml_user_businesses_self ON public.ml_user_businesses;
CREATE POLICY ml_user_businesses_self ON public.ml_user_businesses FOR SELECT TO authenticated
USING ((SELECT auth.uid())=user_id);

CREATE OR REPLACE FUNCTION public.ml_sync_my_memberships()
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE u uuid:=(SELECT auth.uid());
BEGIN
 IF u IS NULL THEN RAISE EXCEPTION 'UNAUTHENTICATED'; END IF;
 INSERT INTO public.ml_user_businesses(business_id,user_id,role,active)
 SELECT m.business_id,m.user_id,m.role,m.active FROM core.business_memberships m WHERE m.user_id=u
 ON CONFLICT(business_id,user_id) DO UPDATE SET role=excluded.role,active=excluded.active;
 RETURN jsonb_build_object('ok',true);
END $$;
REVOKE ALL ON FUNCTION public.ml_sync_my_memberships() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.ml_sync_my_memberships() TO authenticated;

-- The service_role remains server-side; do not expose core schema to anon.
