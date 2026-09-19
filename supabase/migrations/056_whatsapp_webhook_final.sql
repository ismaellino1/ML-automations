-- 056_whatsapp_webhook_final.sql
-- Unified entry point for inbound WhatsApp messages and provider delivery receipts.
--
-- P0.2 CORRECTION (2026-09-19, ML Automações P0 hardening):
-- The original EXCEPTION WHEN OTHERS handler lived at the top level of this
-- function's own BEGIN block. In PL/pgSQL, an exception handler's implicit
-- savepoint is anchored at the START of the block it belongs to - so any
-- error raised anywhere after the initial INSERT (including inside the
-- dispatched ingest_whatsapp_delivery_status_v1 / ingest_whatsapp_event_v1
-- calls) rolled back to before that INSERT, undoing the very audit/dedupe
-- row the handler then tried to update. The UPDATE silently affected 0 rows
-- (the row no longer existed), and the immediate RAISE re-threw on top of
-- that - so a processing failure left literally no trace that the webhook
-- had ever arrived, AND destroyed the event_key dedupe protection against
-- Meta's automatic retries for that exact delivery.
--
-- Fixed by moving the dispatch into its OWN nested BEGIN/EXCEPTION block.
-- Only that inner block's savepoint gets rolled back on failure; the outer
-- INSERT (and its event_key uniqueness) is never touched. The function no
-- longer RAISEs on a processing failure - it returns a structured
-- {ok:false,...} result instead, which matches the contract its only
-- caller already expects: n8n/01_ml_inbound_gateway.json's
-- "03 - ASSERT INGEST" node already does `if ($json.ingest?.ok !== true)
-- throw ...` on the RETURNED value, it never relied on a raised SQL
-- exception. So the caller's ability to detect and react to a failure is
-- unchanged; what changes is that the audit trail now survives it.
--
-- See docs/AUDIT/PHASE_A.md D.1 and
-- supabase/tests/p0/002_p0_2_webhook_atomicity.sql.
--
-- Deliberately out of scope for this fix: automatically re-attempting a
-- FAILED webhook_events row when Meta retries the identical event_key. That
-- retry still returns the cached failure (correct - "retry do Meta não gere
-- processamento repetido descontrolado"). A dedicated reprocessing sweep for
-- rows where processed=true AND result->>'ok'='false' is a reasonable P1
-- follow-up, not a P0.2 requirement (the underlying ingest functions are
-- already idempotent, so such a sweep would be safe to add later without
-- touching this function again).

CREATE TABLE IF NOT EXISTS core.webhook_events (
    id BIGSERIAL PRIMARY KEY,
    provider TEXT NOT NULL,
    event_key TEXT,
    event_type TEXT NOT NULL,
    payload JSONB NOT NULL DEFAULT '{}'::jsonb,
    processed BOOLEAN NOT NULL DEFAULT false,
    result JSONB,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    processed_at TIMESTAMPTZ
);
CREATE UNIQUE INDEX IF NOT EXISTS uq_webhook_events_provider_key
ON core.webhook_events(provider,event_key) WHERE event_key IS NOT NULL;

CREATE OR REPLACE FUNCTION core.ingest_whatsapp_webhook_final(
    p_event JSONB,p_execution_ref TEXT
)
RETURNS JSONB LANGUAGE plpgsql VOLATILE AS $function$
DECLARE
    v_type TEXT:=upper(coalesce(p_event->>'event_type','IGNORE'));
    v_key TEXT:=nullif(p_event->>'event_key','');
    v_event_id BIGINT;
    v_result JSONB;
BEGIN
    BEGIN
      INSERT INTO core.webhook_events(provider,event_key,event_type,payload)
      VALUES('META',v_key,v_type,coalesce(p_event,'{}'::jsonb))
      RETURNING id INTO v_event_id;
    EXCEPTION WHEN unique_violation THEN
      SELECT result INTO v_result FROM core.webhook_events WHERE provider='META' AND event_key=v_key;
      RETURN coalesce(v_result,jsonb_build_object('ok',true,'code','WEBHOOK_DUPLICATE'));
    END;

    -- P0.2: processing runs inside its own sub-transaction (savepoint) so a
    -- failure here rolls back ONLY the processing attempt, never the
    -- webhook_events row inserted above - that row is both our audit trail
    -- and our idempotency guard against Meta's automatic retries, and must
    -- survive even when downstream processing throws.
    BEGIN
      IF v_type='DELIVERY_STATUS' THEN
        v_result:=core.ingest_whatsapp_delivery_status_v1(
          p_event#>>'{channel,external_channel_id}',p_event#>>'{channel,provider}',
          p_event->>'external_message_id',p_event->>'status',nullif(p_event->>'provider_timestamp','')::timestamptz,
          coalesce(p_event->'raw_payload','{}'::jsonb)
        );
      ELSIF v_type='INBOUND_MESSAGE' THEN
        v_result:=core.ingest_whatsapp_event_v1(
          p_event#>>'{channel,external_channel_id}',p_event#>>'{channel,type}',p_event#>>'{channel,provider}',
          p_event#>>'{customer,external_user_id}',p_event#>>'{customer,profile_name}',
          p_event#>>'{message,idempotency_key}',p_event#>>'{message,external_message_id}',p_event#>>'{message,type}',
          coalesce(p_event#>'{message,interaction}','{}'::jsonb),coalesce(p_event#>'{message,media}','{}'::jsonb),
          jsonb_build_object('text',p_event#>>'{message,text}','raw_payload',coalesce(p_event#>'{message,raw_payload}','{}'::jsonb),
                             'reply_to_external_message_id',p_event#>>'{message,reply_to_external_message_id}'),
          nullif(p_event#>>'{message,provider_timestamp}','')::timestamptz,p_execution_ref
        );
      ELSE
        v_result:=jsonb_build_object('ok',true,'code','WEBHOOK_EVENT_IGNORED','event_type',v_type);
      END IF;
    EXCEPTION WHEN OTHERS THEN
      -- Only this inner block's work is rolled back (its own savepoint).
      -- The webhook_events row from the outer INSERT is untouched.
      v_result := jsonb_build_object('ok',false,'code','WEBHOOK_PROCESSING_ERROR','message',SQLERRM,'sqlstate',SQLSTATE);
    END;

    UPDATE core.webhook_events SET processed=true,result=v_result,processed_at=now() WHERE id=v_event_id;
    RETURN v_result;
END;
$function$;
