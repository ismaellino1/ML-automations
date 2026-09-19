
-- 049_observability.sql
CREATE TABLE IF NOT EXISTS core.automation_incidents(
 id BIGSERIAL PRIMARY KEY,business_id UUID,severity TEXT NOT NULL DEFAULT 'ERROR',
 workflow TEXT,execution_id TEXT,node TEXT,error_code TEXT,error_message TEXT,correlation_id TEXT,
 context JSONB NOT NULL DEFAULT '{}'::jsonb,status TEXT NOT NULL DEFAULT 'OPEN' CHECK(status IN('OPEN','ACKNOWLEDGED','RESOLVED')),
 created_at TIMESTAMPTZ NOT NULL DEFAULT now(),resolved_at TIMESTAMPTZ);
CREATE INDEX IF NOT EXISTS idx_incidents_open ON core.automation_incidents(status,severity,created_at DESC);

CREATE OR REPLACE FUNCTION core.record_automation_incident_v1(
 p_business_id UUID,p_severity TEXT,p_workflow TEXT,p_execution_id TEXT,p_node TEXT,p_error_code TEXT,p_error_message TEXT,p_context JSONB
) RETURNS JSONB LANGUAGE plpgsql AS $$
DECLARE v bigint;
BEGIN
 INSERT INTO core.automation_incidents(business_id,severity,workflow,execution_id,node,error_code,error_message,context)
 VALUES(p_business_id,coalesce(p_severity,'ERROR'),p_workflow,p_execution_id,p_node,p_error_code,left(p_error_message,4000),coalesce(p_context,'{}'::jsonb))
 RETURNING id INTO v;
 RETURN jsonb_build_object('ok',true,'incident_id',v);
END $$;
