-- 057_ai_runtime_policy_final.sql
-- Central model policy. GPT-5.6 Luna is the production default for cost-sensitive/high-volume work.

CREATE TABLE IF NOT EXISTS core.ai_runtime_policies (
    business_id UUID PRIMARY KEY REFERENCES core.businesses(id) ON DELETE CASCADE,
    orchestrator_model TEXT NOT NULL DEFAULT 'gpt-5.6-luna',
    response_model TEXT NOT NULL DEFAULT 'gpt-5.6-luna',
    media_model TEXT NOT NULL DEFAULT 'gpt-5.6-luna',
    transcription_model TEXT NOT NULL DEFAULT 'gpt-4o-mini-transcribe',
    orchestrator_reasoning_effort TEXT NOT NULL DEFAULT 'medium'
        CHECK (orchestrator_reasoning_effort IN ('none','low','medium','high','xhigh','max')),
    response_reasoning_effort TEXT NOT NULL DEFAULT 'low'
        CHECK (response_reasoning_effort IN ('none','low','medium','high','xhigh','max')),
    max_orchestrator_output_tokens INTEGER NOT NULL DEFAULT 1800 CHECK (max_orchestrator_output_tokens BETWEEN 256 AND 16000),
    max_response_output_tokens INTEGER NOT NULL DEFAULT 900 CHECK (max_response_output_tokens BETWEEN 128 AND 8000),
    enabled BOOLEAN NOT NULL DEFAULT TRUE,
    metadata JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

DROP TRIGGER IF EXISTS trg_ai_runtime_policies_updated_at
ON core.ai_runtime_policies;

CREATE TRIGGER trg_ai_runtime_policies_updated_at
BEFORE UPDATE ON core.ai_runtime_policies
FOR EACH ROW
EXECUTE FUNCTION core.set_updated_at();

INSERT INTO core.ai_runtime_policies (business_id)
SELECT b.id
FROM core.businesses b
ON CONFLICT (business_id) DO NOTHING;

CREATE OR REPLACE FUNCTION core.get_ai_runtime_policy_v1(p_business_id UUID)
RETURNS JSONB
LANGUAGE sql
STABLE
AS $function$
SELECT jsonb_build_object(
    'orchestrator_model', p.orchestrator_model,
    'response_model', p.response_model,
    'media_model', p.media_model,
    'transcription_model', p.transcription_model,
    'orchestrator_reasoning_effort', p.orchestrator_reasoning_effort,
    'response_reasoning_effort', p.response_reasoning_effort,
    'max_orchestrator_output_tokens', p.max_orchestrator_output_tokens,
    'max_response_output_tokens', p.max_response_output_tokens,
    'enabled', p.enabled
)
FROM core.ai_runtime_policies p
WHERE p.business_id = p_business_id;
$function$;
