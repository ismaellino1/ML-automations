-- 046_automation_policy_foundation.sql
-- Production foundation only. There are deliberately NO provisional/no-op functions here.
-- Final reminder/reactivation/campaign functions are defined in 052.
-- Final waitlist automation is defined in 053.

CREATE TABLE IF NOT EXISTS core.automation_policies (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    business_id UUID NOT NULL REFERENCES core.businesses(id) ON DELETE CASCADE,
    policy_type TEXT NOT NULL,
    enabled BOOLEAN NOT NULL DEFAULT TRUE,
    config JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (business_id, policy_type)
);

CREATE INDEX IF NOT EXISTS idx_automation_policies_business_enabled
ON core.automation_policies (business_id, enabled, policy_type);

DROP TRIGGER IF EXISTS trg_automation_policies_updated_at
ON core.automation_policies;

CREATE TRIGGER trg_automation_policies_updated_at
BEFORE UPDATE ON core.automation_policies
FOR EACH ROW
EXECUTE FUNCTION core.set_updated_at();
