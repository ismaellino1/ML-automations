-- 056_whatsapp_webhook_final.sql
-- Unified entry point for inbound WhatsApp messages and provider delivery receipts.

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

    IF v_type='DELIVERY_STATUS' THEN
      v_result:=core.ingest_whatsapp_delivery_status_v1(
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

    UPDATE core.webhook_events SET processed=true,result=v_result,processed_at=now() WHERE id=v_event_id;
    RETURN v_result;
EXCEPTION WHEN OTHERS THEN
    UPDATE core.webhook_events SET processed=true,result=jsonb_build_object('ok',false,'code','WEBHOOK_PROCESSING_ERROR','message',SQLERRM),processed_at=now()
    WHERE id=v_event_id;
    RAISE;
END;
$function$;
