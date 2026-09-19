-- 054_runtime_final.sql
-- Final assistant dispatcher/finalizer. All external side effects become durable jobs.

CREATE OR REPLACE FUNCTION core.enqueue_prepared_cancellation_outbound_v1(
    p_business_id UUID,p_appointment_id UUID,p_execution_ref TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
VOLATILE
AS $function$
DECLARE
    v_out JSONB;
    v_job UUID;
    v_customer_id UUID;
    v_settings JSONB;
    v_template_name TEXT;
    v_template_language TEXT;
    v_content JSONB;
BEGIN
    v_out := core.prepare_appointment_cancellation_outbound(p_business_id,p_appointment_id);
    IF coalesce((v_out->>'ok')::boolean,false) IS NOT TRUE THEN RETURN v_out; END IF;

    IF coalesce((v_out->>'should_send')::boolean,false) THEN
        v_job := core.enqueue_integration_job_v1(
          p_business_id,'WHATSAPP_OUTBOUND','SEND',
          jsonb_build_object(
            'internal_message_id',v_out->>'internal_message_id',
            'phone_number_id',v_out->>'phone_number_id',
            'recipient',v_out->>'recipient',
            'graph_api_version','v26.0',
            'meta_payload',v_out->'meta_payload',
            'notification_type','APPOINTMENT_CANCELLED'
          ),
          'CANCEL_NOTIFY:'||p_appointment_id,'APPOINTMENT',p_appointment_id,70,8,now(),p_execution_ref,NULL
        );
        RETURN v_out || jsonb_build_object('job_id',v_job,'queued',true);
    END IF;

    -- Outside the 24h free-form window: use a configured utility template if available.
    IF v_out->>'code'='WHATSAPP_TEMPLATE_REQUIRED' THEN
        SELECT a.customer_id INTO v_customer_id FROM core.appointments a
        WHERE a.business_id=p_business_id AND a.id=p_appointment_id;
        SELECT coalesce(bs.extra_settings,'{}'::jsonb) INTO v_settings
        FROM core.business_settings bs WHERE bs.business_id=p_business_id;
        v_template_name:=nullif(v_settings#>>'{whatsapp_templates,appointment_cancelled,name}','');
        v_template_language:=coalesce(nullif(v_settings#>>'{whatsapp_templates,appointment_cancelled,language}',''),'pt_BR');
        IF v_template_name IS NULL THEN
          RETURN v_out || jsonb_build_object('queued',false,'configuration_required','appointment_cancelled template');
        END IF;
        v_content:=jsonb_build_object(
          'text','Seu agendamento foi cancelado. Abra a conversa para ver os detalhes ou procurar outro horário.',
          'template_name',v_template_name,
          'template_language',v_template_language,
          'template_components',coalesce(v_settings#>'{whatsapp_templates,appointment_cancelled,components}','[]'::jsonb),
          'metadata',jsonb_build_object('appointment_id',p_appointment_id)
        );
        RETURN core.queue_outbound_notification_v3(
          p_business_id,v_customer_id,'APPOINTMENT_CANCELLED',v_content,
          'CANCEL_TEMPLATE:'||p_appointment_id,p_execution_ref,'{}'::jsonb,'INFORMATION'
        );
    END IF;

    RETURN v_out || jsonb_build_object('queued',false);
END;
$function$;

CREATE OR REPLACE FUNCTION core.execute_assistant_action_final(
    p_business_id UUID,
    p_conversation_id UUID,
    p_customer_id UUID,
    p_channel_type TEXT,
    p_provider TEXT,
    p_action TEXT,
    p_arguments JSONB,
    p_execution_ref TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
VOLATILE
AS $function$
DECLARE
    v_action TEXT:=upper(coalesce(p_action,'NONE'));
    v_result JSONB;
    v_cal JSONB;
    v_src JSONB;
    v_rep JSONB;
    v_appt UUID;
    v_offer UUID;
BEGIN
    IF v_action='UPDATE_MARKETING_PREFERENCE' THEN
      RETURN core.set_marketing_consent_v2(
        p_business_id,p_customer_id,coalesce((p_arguments->>'marketing_opt_in')::boolean,false),'ASSISTANT'
      );
    END IF;

    IF v_action='JOIN_WAITLIST' THEN
      BEGIN
        RETURN core.join_waitlist_v2(
          p_business_id,p_conversation_id,p_customer_id,
          nullif(p_arguments->>'service_id','')::uuid,
          nullif(p_arguments->>'professional_id','')::uuid,
          nullif(p_arguments->>'date','')::date,
          coalesce(nullif(p_arguments->>'date_until','')::date,nullif(p_arguments->>'date','')::date),
          nullif(p_arguments->>'time_from','')::time,
          nullif(p_arguments->>'time_until','')::time,
          'ASSISTANT'
        );
      EXCEPTION WHEN invalid_text_representation THEN
        RETURN jsonb_build_object('ok',false,'code','INVALID_WAITLIST_ARGUMENT');
      END;
    END IF;

    IF v_action='LEAVE_WAITLIST' THEN
      BEGIN
        RETURN core.leave_waitlist_v2(p_business_id,p_customer_id,nullif(p_arguments->>'waitlist_id','')::uuid);
      EXCEPTION WHEN invalid_text_representation THEN
        RETURN jsonb_build_object('ok',false,'code','INVALID_WAITLIST_ID');
      END;
    END IF;

    v_result:=core.execute_assistant_action_v3(
      p_business_id,p_conversation_id,p_customer_id,p_channel_type,p_provider,v_action,coalesce(p_arguments,'{}'::jsonb)
    );

    IF coalesce((v_result->>'ok')::boolean,false) IS NOT TRUE THEN RETURN v_result; END IF;

    -- Simple Calendar operation.
    v_cal:=v_result->'calendar_sync';
    IF coalesce((v_cal->>'required')::boolean,false) THEN
      BEGIN
        PERFORM core.enqueue_calendar_sync_job_v2(
          p_business_id,(v_cal->>'appointment_id')::uuid,v_cal->>'operation',p_execution_ref,NULL
        );
      EXCEPTION WHEN OTHERS THEN
        PERFORM core.record_automation_incident_v1(
          p_business_id,'ERROR','CORE_RUNTIME',p_execution_ref,'CALENDAR_ENQUEUE','CALENDAR_ENQUEUE_FAILED',SQLERRM,
          jsonb_build_object('calendar_sync',v_cal)
        );
      END;
    END IF;

    -- Reschedule is represented as two independent, durable side effects.
    IF coalesce((v_result#>>'{calendar_reschedule,required}')::boolean,false) THEN
      v_src:=v_result#>'{calendar_reschedule,source}';
      v_rep:=v_result#>'{calendar_reschedule,replacement}';
      IF coalesce((v_src->>'delete_required')::boolean,false) THEN
        PERFORM core.enqueue_calendar_sync_job_v2(p_business_id,(v_src->>'appointment_id')::uuid,'DELETE',p_execution_ref,NULL);
      END IF;
      IF coalesce((v_rep->>'create_required')::boolean,false) THEN
        PERFORM core.enqueue_calendar_sync_job_v2(p_business_id,(v_rep->>'appointment_id')::uuid,'CREATE',p_execution_ref,NULL);
      END IF;
    END IF;

    -- A confirmed slot may have originated from our waitlist engine.
    IF v_action='SELECT_SLOT' THEN
      BEGIN
        v_offer:=coalesce(
          nullif(v_result#>>'{result,slot_offer_id}','')::uuid,
          nullif(v_result#>>'{result,selection,slot_offer_id}','')::uuid
        );
        v_appt:=coalesce(
          nullif(v_result#>>'{result,appointment,appointment_id}','')::uuid,
          nullif(v_result#>>'{result,replacement,appointment_id}','')::uuid,
          nullif(v_result#>>'{result,replacement_appointment_id}','')::uuid
        );
        IF v_offer IS NOT NULL AND v_appt IS NOT NULL THEN
          PERFORM core.mark_waitlist_booked_from_offer_v1(p_business_id,p_customer_id,v_offer,v_appt);
          PERFORM core.attribute_campaign_conversion_v1(p_business_id,p_customer_id,v_appt,'APPOINTMENT_CONFIRMED');
        END IF;
      EXCEPTION WHEN OTHERS THEN
        PERFORM core.record_automation_incident_v1(
          p_business_id,'WARNING','CORE_RUNTIME',p_execution_ref,'ATTRIBUTION','POST_CONFIRM_HOOK_FAILED',SQLERRM,
          jsonb_build_object('execution',v_result)
        );
      END;
    END IF;

    -- Customer-originated cancellation gets its confirmation from the same conversational turn.
    -- Proactive professional/business cancellation is handled by the Control Plane helper.
    RETURN v_result;
END;
$function$;

CREATE OR REPLACE FUNCTION core.finalize_conversation_job_final(
    p_job_id UUID,p_command JSONB,p_execution JSONB,p_response JSONB,p_execution_ref TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
VOLATILE
AS $function$
DECLARE
    v_job core.integration_jobs%ROWTYPE;
    v_payload JSONB;
    v_ctx JSONB;
    v_final JSONB;
    v_delivery JSONB;
    v_kind TEXT;
    v_route TEXT;
    v_response_type TEXT;
    v_should_send BOOLEAN;
BEGIN
    SELECT * INTO v_job FROM core.integration_jobs WHERE id=p_job_id FOR UPDATE;
    IF NOT FOUND THEN RETURN jsonb_build_object('ok',false,'code','JOB_NOT_FOUND'); END IF;
    IF v_job.status<>'RUNNING' THEN RETURN jsonb_build_object('ok',false,'code','JOB_NOT_RUNNING','status',v_job.status); END IF;

    v_payload:=v_job.payload;
    v_ctx:=v_payload->'context';
    v_kind:=coalesce(p_command->>'kind','NEED_INFORMATION');
    v_route:=CASE WHEN v_kind='BUSINESS_ACTION' THEN 'CORE' WHEN v_kind='HUMAN_HANDOFF' THEN 'HUMAN_HANDOFF' ELSE 'DIRECT_RESPONSE' END;
    v_response_type:=coalesce(p_response->>'response_type','GENERAL');
    v_should_send:=coalesce((p_response->>'should_send')::boolean,true);

    IF v_kind='HUMAN_HANDOFF' THEN
      UPDATE core.conversations SET automation_mode='HUMAN',pending_action=NULL,updated_at=now()
      WHERE business_id=(v_ctx#>>'{business,id}')::uuid AND id=(v_ctx#>>'{conversation,id}')::uuid;
    END IF;

    v_final:=core.finalize_assistant_turn(
      (v_ctx#>>'{business,id}')::uuid,
      (v_ctx#>>'{conversation,id}')::uuid,
      (v_ctx#>>'{customer,id}')::uuid,
      (v_ctx#>>'{customer,channel_id}')::uuid,
      v_ctx#>>'{channel,channel_type}',
      v_ctx#>>'{channel,provider}',
      (v_ctx#>>'{turn,message_id}')::uuid,
      p_command->>'intent',
      coalesce((p_command->>'confidence')::numeric,0),
      v_kind,
      v_route,
      coalesce(p_command->>'action','NONE'),
      p_response->>'text',
      v_response_type,
      coalesce(p_response->>'source','RESPONSE_ENGINE'),
      v_should_send
    );

    IF coalesce((v_final->>'ok')::boolean,false) IS NOT TRUE THEN
      PERFORM core.fail_integration_job_v1(p_job_id,'FINALIZE_ASSISTANT_TURN_FAILED',jsonb_build_object('finalization',v_final));
      RETURN jsonb_build_object('ok',false,'code','FINALIZATION_FAILED','finalization',v_final);
    END IF;

    IF v_should_send AND nullif(p_response->>'text','') IS NOT NULL THEN
      v_delivery:=core.queue_outbound_notification_v3(
        (v_ctx#>>'{business,id}')::uuid,
        (v_ctx#>>'{customer,id}')::uuid,
        'CONVERSATION_RESPONSE',
        jsonb_build_object('text',p_response->>'text','metadata',jsonb_build_object('turn_job_id',p_job_id)),
        'TURN:'||(v_ctx#>>'{turn,message_id}'),p_execution_ref,
        coalesce(p_execution,'{}'::jsonb),v_response_type
      );
      IF coalesce((v_delivery->>'ok')::boolean,false) IS NOT TRUE THEN
        PERFORM core.fail_integration_job_v1(p_job_id,'OUTBOUND_QUEUE_FAILED',jsonb_build_object('delivery',v_delivery));
        RETURN jsonb_build_object('ok',false,'code','OUTBOUND_QUEUE_FAILED','delivery',v_delivery);
      END IF;
    END IF;

    PERFORM core.complete_integration_job_v1(
      p_job_id,jsonb_build_object('command',p_command,'execution',p_execution,'response',p_response,'finalization',v_final,'delivery',v_delivery)
    );
    RETURN jsonb_build_object('ok',true,'code','TURN_FINALIZED','finalization',v_final,'delivery',v_delivery);
END;
$function$;
