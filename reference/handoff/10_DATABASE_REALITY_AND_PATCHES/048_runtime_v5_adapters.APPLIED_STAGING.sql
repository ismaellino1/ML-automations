
-- 048_runtime_v5_adapters.sql
CREATE OR REPLACE FUNCTION core.queue_outbound_notification_v1(
 p_business_id UUID,p_customer_id UUID,p_notification_type TEXT,p_content JSONB,p_dedupe_key TEXT,p_execution_ref TEXT
) RETURNS JSONB LANGUAGE plpgsql AS $$
DECLARE cc record; bc record; msg jsonb; job_id uuid; text_value text; payload jsonb;
BEGIN
 SELECT * INTO cc FROM core.customer_channels
 WHERE business_id=p_business_id AND customer_id=p_customer_id AND channel_type='WHATSAPP' AND provider='META' AND active=true
 ORDER BY is_primary DESC,updated_at DESC LIMIT 1;
 IF NOT FOUND THEN RETURN jsonb_build_object('ok',false,'code','CUSTOMER_CHANNEL_NOT_FOUND'); END IF;
 SELECT * INTO bc FROM core.business_channels WHERE business_id=p_business_id AND channel_type='WHATSAPP' AND provider='META' AND status='ACTIVE'
 ORDER BY updated_at DESC LIMIT 1;
 IF NOT FOUND THEN RETURN jsonb_build_object('ok',false,'code','BUSINESS_CHANNEL_NOT_FOUND'); END IF;
 text_value:=coalesce(p_content->>'text',
  CASE upper(p_notification_type)
   WHEN 'APPOINTMENT_REMINDER' THEN 'Lembrete: você tem um horário marcado em breve.'
   ELSE 'Temos uma atualização para você.' END);
 payload:=jsonb_build_object('messaging_product','whatsapp','recipient_type','individual','to',cc.external_user_id,'type','text',
  'text',jsonb_build_object('body',text_value));
 job_id:=core.enqueue_integration_job_v1(p_business_id,'WHATSAPP_OUTBOUND','SEND',
  jsonb_build_object('phone_number_id',bc.external_channel_id,'recipient',cc.external_user_id,'meta_payload',payload,
    'graph_api_version','v26.0','notification_type',p_notification_type),
  p_dedupe_key,'CUSTOMER',p_customer_id,100,8,now(),p_execution_ref,NULL);
 RETURN jsonb_build_object('ok',true,'code','OUTBOUND_QUEUED','job_id',job_id);
END $$;

CREATE OR REPLACE FUNCTION core.claim_outbound_delivery_batch(p_limit INTEGER,p_worker_ref TEXT)
RETURNS TABLE(job JSONB) LANGUAGE sql AS $$
SELECT jsonb_build_object('job_id',j.id,'business_id',j.business_id,'phone_number_id',j.payload->>'phone_number_id',
 'recipient',j.payload->>'recipient','graph_api_version',coalesce(j.payload->>'graph_api_version','v26.0'),
 'meta_payload',j.payload->'meta_payload')
FROM core.claim_integration_jobs_v1('WHATSAPP_OUTBOUND',p_limit,p_worker_ref,120) q(job)
JOIN LATERAL jsonb_to_record(q.job) AS j0(id uuid) ON true
JOIN core.integration_jobs j ON j.id=j0.id $$;
CREATE OR REPLACE FUNCTION core.complete_outbound_delivery(p_job_id UUID,p_external_message_id TEXT,p_provider_response JSONB)
RETURNS JSONB LANGUAGE sql AS $$ SELECT core.complete_integration_job_v1(p_job_id,p_provider_response||jsonb_build_object('external_message_id',p_external_message_id)) $$;
CREATE OR REPLACE FUNCTION core.fail_outbound_delivery(p_job_id UUID,p_error TEXT,p_provider_response JSONB)
RETURNS JSONB LANGUAGE sql AS $$ SELECT core.fail_integration_job_v1(p_job_id,p_error,p_provider_response) $$;

CREATE OR REPLACE FUNCTION core.claim_calendar_sync_batch(p_limit INTEGER,p_worker_ref TEXT)
RETURNS TABLE(job JSONB) LANGUAGE sql AS $$
SELECT j.payload||jsonb_build_object('job_id',j.id,'business_id',j.business_id,'operation',j.operation)
FROM core.claim_integration_jobs_v1('CALENDAR_SYNC',p_limit,p_worker_ref,180) q(job)
JOIN LATERAL jsonb_to_record(q.job) AS j0(id uuid) ON true
JOIN core.integration_jobs j ON j.id=j0.id $$;
CREATE OR REPLACE FUNCTION core.complete_calendar_sync_job(p_job_id UUID,p_external_event_id TEXT,p_provider_response JSONB)
RETURNS JSONB LANGUAGE sql AS $$ SELECT core.complete_integration_job_v1(p_job_id,p_provider_response||jsonb_build_object('external_event_id',p_external_event_id)) $$;
CREATE OR REPLACE FUNCTION core.fail_calendar_sync_job(p_job_id UUID,p_error TEXT,p_provider_response JSONB)
RETURNS JSONB LANGUAGE sql AS $$ SELECT core.fail_integration_job_v1(p_job_id,p_error,p_provider_response) $$;

CREATE OR REPLACE FUNCTION core.ingest_whatsapp_event_v1(
 p_external_channel_id TEXT,p_channel_type TEXT,p_provider TEXT,p_external_user_id TEXT,p_profile_name TEXT,
 p_idempotency_key TEXT,p_external_message_id TEXT,p_message_type TEXT,p_interaction JSONB,p_media JSONB,p_envelope JSONB,
 p_provider_timestamp TIMESTAMPTZ,p_execution_ref TEXT
) RETURNS JSONB LANGUAGE plpgsql AS $$
DECLARE bc record; prep jsonb; message_id uuid; business_id uuid; context jsonb; asset_id uuid; payload jsonb;
BEGIN
 SELECT * INTO bc FROM core.business_channels WHERE provider=p_provider AND external_channel_id=p_external_channel_id AND status='ACTIVE' LIMIT 1;
 IF NOT FOUND THEN RETURN jsonb_build_object('ok',false,'code','BUSINESS_CHANNEL_NOT_FOUND'); END IF;
 business_id:=bc.business_id;
 prep:=core.prepare_assistant_turn(
   (SELECT business_code FROM core.businesses WHERE id=business_id),p_channel_type,p_provider,p_external_user_id,
   p_idempotency_key,p_external_message_id,p_message_type,p_envelope->>'text',
   coalesce(p_envelope->'raw_payload','{}'::jsonb),p_provider_timestamp,20);
 IF coalesce((prep#>>'{turn,should_process}')::boolean,false) IS NOT TRUE THEN
   RETURN jsonb_build_object('ok',true,'code','DUPLICATE_OR_IGNORED','context',prep);
 END IF;
 message_id:=(prep#>>'{turn,message_id}')::uuid;
 context:=prep;
 payload:=jsonb_build_object('message_id',message_id,'message',jsonb_build_object('type',p_message_type,'text',p_envelope->>'text',
   'interaction',coalesce(p_interaction,'{}'::jsonb)),'context',context);

 IF lower(p_message_type) IN('audio','image','document','video','sticker') AND nullif(p_media->>'id','') IS NOT NULL THEN
   INSERT INTO core.media_assets(business_id,message_id,media_id,mime_type,filename,caption)
   VALUES(business_id,message_id,p_media->>'id',p_media->>'mime_type',p_media->>'filename',p_media->>'caption')
   ON CONFLICT(business_id,provider,media_id) DO UPDATE SET updated_at=now()
   RETURNING id INTO asset_id;
   PERFORM core.enqueue_integration_job_v1(business_id,'MEDIA_PROCESS','PROCESS',
      jsonb_build_object('media_asset_id',asset_id,'media_id',p_media->>'id','media_type',p_message_type,'mime_type',p_media->>'mime_type',
       'filename',p_media->>'filename','caption',p_media->>'caption','message_id',message_id,'conversation_payload',payload),
      'MEDIA:'||p_provider||':'||(p_media->>'id'),'MESSAGE',message_id,40,6,now(),p_execution_ref,NULL);
   RETURN jsonb_build_object('ok',true,'code','MEDIA_DEFERRED','message_id',message_id,'media_asset_id',asset_id);
 ELSE
   PERFORM core.enqueue_integration_job_v1(business_id,'CONVERSATION_TURN','PROCESS',payload,
     'CONVERSATION:'||message_id,'MESSAGE',message_id,50,5,now(),p_execution_ref,NULL);
   RETURN jsonb_build_object('ok',true,'code','CONVERSATION_QUEUED','message_id',message_id);
 END IF;
END $$;

CREATE OR REPLACE FUNCTION core.claim_conversation_turn_batch(p_limit INTEGER,p_worker_ref TEXT)
RETURNS TABLE(job JSONB) LANGUAGE sql AS $$
SELECT jsonb_build_object('job_id',j.id,'business_id',j.business_id)
FROM core.claim_integration_jobs_v1('CONVERSATION_TURN',p_limit,p_worker_ref,300) q(job)
JOIN LATERAL jsonb_to_record(q.job) AS j0(id uuid) ON true JOIN core.integration_jobs j ON j.id=j0.id $$;

CREATE OR REPLACE FUNCTION core.prepare_conversation_job_v1(p_job_id UUID,p_execution_ref TEXT)
RETURNS JSONB LANGUAGE plpgsql AS $$
DECLARE j core.integration_jobs%rowtype; payload jsonb; b uuid; q text;
BEGIN
 SELECT * INTO j FROM core.integration_jobs WHERE id=p_job_id;
 IF NOT FOUND THEN RETURN jsonb_build_object('ok',false,'code','JOB_NOT_FOUND'); END IF;
 payload:=j.payload;b:=j.business_id;q:=coalesce(payload#>>'{message,text}',payload#>>'{media_context,summary}','');
 payload:=jsonb_set(payload,'{context,catalog_context}',core.get_catalog_context_v1(b),true);
 payload:=jsonb_set(payload,'{context,knowledge_context}',core.search_business_knowledge_v1(b,q,8),true);
 payload:=jsonb_set(payload,'{context,promotion_context}',
   coalesce((SELECT jsonb_agg(jsonb_build_object('campaign_id',id,'name',name,'content',content,'ends_at',ends_at))
     FROM core.campaigns WHERE business_id=b AND status='RUNNING' AND (ends_at IS NULL OR ends_at>now())),'[]'::jsonb),true);
 RETURN payload||jsonb_build_object('job_id',j.id,'ok',true);
END $$;

CREATE OR REPLACE FUNCTION core.execute_assistant_action_v5(
 p_business_id UUID,p_conversation_id UUID,p_customer_id UUID,p_channel_type TEXT,p_provider TEXT,p_action TEXT,p_arguments JSONB,p_execution_ref TEXT
) RETURNS JSONB LANGUAGE plpgsql AS $$
DECLARE r jsonb; c jsonb; src jsonb; rep jsonb;
BEGIN
 IF p_action='UPDATE_MARKETING_PREFERENCE' THEN
  RETURN core.set_marketing_consent_v1(p_business_id,p_customer_id,coalesce((p_arguments->>'marketing_opt_in')::boolean,false),'ASSISTANT');
 END IF;
 IF p_action='LEAVE_WAITLIST' THEN
  BEGIN
   EXECUTE 'SELECT core.leave_waitlist($1,$2,$3)' INTO r USING p_business_id,p_customer_id,nullif(p_arguments->>'waitlist_id','')::uuid;
   RETURN r;
  EXCEPTION WHEN undefined_function THEN RETURN jsonb_build_object('ok',false,'code','LEAVE_WAITLIST_NOT_SUPPORTED'); END;
 END IF;
 r:=core.execute_assistant_action_v3(p_business_id,p_conversation_id,p_customer_id,p_channel_type,p_provider,p_action,p_arguments);
 IF coalesce((r->>'ok')::boolean,false) IS TRUE THEN
   c:=r->'calendar_sync';
   IF coalesce((c->>'required')::boolean,false) THEN
     PERFORM core.enqueue_integration_job_v1(p_business_id,'CALENDAR_SYNC',coalesce(c->>'operation','CREATE'),
       c||jsonb_build_object('appointment_id',c->>'appointment_id'),
       'CAL:'||coalesce(c->>'operation','CREATE')||':'||(c->>'appointment_id'),'APPOINTMENT',nullif(c->>'appointment_id','')::uuid,60,8,now(),p_execution_ref,NULL);
   END IF;
   IF coalesce((r#>>'{calendar_reschedule,required}')::boolean,false) THEN
     src:=r#>'{calendar_reschedule,source}';rep:=r#>'{calendar_reschedule,replacement}';
     IF coalesce((src->>'delete_required')::boolean,false) THEN
       PERFORM core.enqueue_integration_job_v1(p_business_id,'CALENDAR_SYNC','DELETE',src,
        'CAL:DELETE:'||(src->>'appointment_id'),'APPOINTMENT',(src->>'appointment_id')::uuid,50,8,now(),p_execution_ref,NULL);
     END IF;
     IF coalesce((rep->>'create_required')::boolean,false) THEN
       PERFORM core.enqueue_integration_job_v1(p_business_id,'CALENDAR_SYNC','CREATE',rep,
        'CAL:CREATE:'||(rep->>'appointment_id'),'APPOINTMENT',(rep->>'appointment_id')::uuid,60,8,now(),p_execution_ref,NULL);
     END IF;
   END IF;
 END IF;
 RETURN r;
END $$;

CREATE OR REPLACE FUNCTION core.finalize_conversation_job_v1(
 p_job_id UUID,p_command JSONB,p_execution JSONB,p_response JSONB,p_execution_ref TEXT
) RETURNS JSONB LANGUAGE plpgsql AS $$
DECLARE j core.integration_jobs%rowtype; p jsonb; ctx jsonb; f jsonb; q jsonb;
BEGIN
 SELECT * INTO j FROM core.integration_jobs WHERE id=p_job_id FOR UPDATE;
 IF NOT FOUND THEN RETURN jsonb_build_object('ok',false,'code','JOB_NOT_FOUND'); END IF;
 p:=j.payload;ctx:=p->'context';
 f:=core.finalize_assistant_turn(
  (ctx#>>'{business,id}')::uuid,(ctx#>>'{conversation,id}')::uuid,(ctx#>>'{customer,id}')::uuid,
  (ctx#>>'{customer,channel_id}')::uuid,ctx#>>'{channel,channel_type}',ctx#>>'{channel,provider}',
  (ctx#>>'{turn,message_id}')::uuid,p_command->>'intent',coalesce((p_command->>'confidence')::numeric,0),
  p_command->>'kind',coalesce(p_command->>'route',CASE WHEN p_command->>'kind'='BUSINESS_ACTION' THEN 'CORE' ELSE 'DIRECT_RESPONSE' END),
  p_command->>'action',p_response->>'text',p_response->>'response_type',coalesce(p_response->>'source','RESPONSE_ENGINE'),
  coalesce((p_response->>'should_send')::boolean,true));
 IF coalesce((f->>'should_send')::boolean,false) THEN
   q:=core.queue_outbound_notification_v1((ctx#>>'{business,id}')::uuid,(ctx#>>'{customer,id}')::uuid,'CONVERSATION_RESPONSE',
      jsonb_build_object('text',p_response->>'text'),
      'TURN:'||(ctx#>>'{turn,message_id}'),p_execution_ref);
 END IF;
 PERFORM core.complete_integration_job_v1(p_job_id,jsonb_build_object('finalization',f,'execution',p_execution));
 RETURN jsonb_build_object('ok',true,'code','TURN_FINALIZED','finalization',f,'delivery',q);
END $$;
