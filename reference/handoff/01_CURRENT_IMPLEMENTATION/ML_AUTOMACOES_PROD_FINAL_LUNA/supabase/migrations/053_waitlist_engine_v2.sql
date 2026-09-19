-- 053_waitlist_engine_v2.sql
-- Canonical, tenant-safe, idempotent waitlist engine integrated with slot offers and outbox.

CREATE TABLE IF NOT EXISTS core.waitlist_subscriptions_v2 (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    business_id UUID NOT NULL REFERENCES core.businesses(id) ON DELETE CASCADE,
    customer_id UUID NOT NULL,
    conversation_id UUID NOT NULL,
    service_id UUID NOT NULL,
    professional_id UUID,
    date_from DATE NOT NULL,
    date_until DATE NOT NULL,
    time_from TIME,
    time_until TIME,
    status TEXT NOT NULL DEFAULT 'WAITING'
        CHECK (status IN ('WAITING','OFFERED','BOOKED','CANCELLED','EXPIRED')),
    last_slot_offer_id UUID,
    offer_expires_at TIMESTAMPTZ,
    last_checked_at TIMESTAMPTZ,
    source TEXT NOT NULL DEFAULT 'ASSISTANT',
    metadata JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT fk_waitlist_v2_customer
      FOREIGN KEY (business_id,customer_id) REFERENCES core.customers(business_id,id) ON DELETE CASCADE,
    CONSTRAINT fk_waitlist_v2_conversation
      FOREIGN KEY (business_id,conversation_id) REFERENCES core.conversations(business_id,id) ON DELETE CASCADE,
    CONSTRAINT fk_waitlist_v2_service
      FOREIGN KEY (business_id,service_id) REFERENCES core.services(business_id,id) ON DELETE RESTRICT,
    CONSTRAINT chk_waitlist_v2_dates CHECK (date_from <= date_until),
    CONSTRAINT chk_waitlist_v2_times CHECK (time_from IS NULL OR time_until IS NULL OR time_from < time_until)
);

CREATE INDEX IF NOT EXISTS idx_waitlist_v2_claim
ON core.waitlist_subscriptions_v2(status,date_from,date_until,created_at)
WHERE status IN ('WAITING','OFFERED');

CREATE UNIQUE INDEX IF NOT EXISTS uq_waitlist_v2_active_request
ON core.waitlist_subscriptions_v2(
  business_id,customer_id,service_id,
  coalesce(professional_id,'00000000-0000-0000-0000-000000000000'::uuid),
  date_from,date_until,
  coalesce(time_from,'00:00'::time),coalesce(time_until,'23:59:59'::time)
)
WHERE status IN ('WAITING','OFFERED');

CREATE OR REPLACE FUNCTION core.join_waitlist_v2(
    p_business_id UUID,
    p_conversation_id UUID,
    p_customer_id UUID,
    p_service_id UUID,
    p_professional_id UUID DEFAULT NULL,
    p_date_from DATE DEFAULT NULL,
    p_date_until DATE DEFAULT NULL,
    p_time_from TIME DEFAULT NULL,
    p_time_until TIME DEFAULT NULL,
    p_source TEXT DEFAULT 'ASSISTANT'
)
RETURNS JSONB
LANGUAGE plpgsql
VOLATILE
AS $function$
DECLARE
    v_business core.businesses%ROWTYPE;
    v_settings core.business_settings%ROWTYPE;
    v_today DATE;
    v_from DATE;
    v_until DATE;
    v_existing core.waitlist_subscriptions_v2%ROWTYPE;
    v_row core.waitlist_subscriptions_v2%ROWTYPE;
BEGIN
    SELECT * INTO v_business FROM core.businesses
    WHERE id=p_business_id AND status='ACTIVE' LIMIT 1;
    IF NOT FOUND THEN RETURN jsonb_build_object('ok',false,'code','BUSINESS_NOT_FOUND'); END IF;

    SELECT * INTO v_settings FROM core.business_settings WHERE business_id=p_business_id LIMIT 1;
    IF NOT FOUND OR coalesce(v_settings.waitlist_enabled,false) IS NOT TRUE THEN
        RETURN jsonb_build_object('ok',false,'code','WAITLIST_DISABLED');
    END IF;

    IF NOT EXISTS (
      SELECT 1 FROM core.conversations c
      WHERE c.business_id=p_business_id AND c.id=p_conversation_id
        AND c.customer_id=p_customer_id AND c.status='OPEN'
    ) THEN
      RETURN jsonb_build_object('ok',false,'code','INVALID_CONVERSATION_CONTEXT');
    END IF;

    IF p_service_id IS NULL OR NOT EXISTS (
      SELECT 1 FROM core.services s
      WHERE s.business_id=p_business_id AND s.id=p_service_id AND s.active=true AND s.online_booking_enabled=true
    ) THEN
      RETURN jsonb_build_object('ok',false,'code','SERVICE_NOT_AVAILABLE');
    END IF;

    IF p_professional_id IS NOT NULL AND NOT EXISTS (
      SELECT 1 FROM core.professionals p
      WHERE p.business_id=p_business_id AND p.id=p_professional_id AND p.active=true AND p.online_booking_enabled=true
    ) THEN
      RETURN jsonb_build_object('ok',false,'code','PROFESSIONAL_NOT_AVAILABLE');
    END IF;

    v_today := (now() AT TIME ZONE v_business.timezone)::date;
    v_from := greatest(coalesce(p_date_from,v_today),v_today);
    v_until := least(
      coalesce(p_date_until,v_from + 7),
      v_today + greatest(coalesce(v_settings.maximum_booking_horizon_days,60),1)
    );

    IF v_until < v_from THEN RETURN jsonb_build_object('ok',false,'code','INVALID_WAITLIST_DATE_RANGE'); END IF;
    IF p_time_from IS NOT NULL AND p_time_until IS NOT NULL AND p_time_from >= p_time_until THEN
      RETURN jsonb_build_object('ok',false,'code','INVALID_WAITLIST_TIME_RANGE');
    END IF;

    SELECT * INTO v_existing
    FROM core.waitlist_subscriptions_v2 w
    WHERE w.business_id=p_business_id AND w.customer_id=p_customer_id
      AND w.service_id=p_service_id
      AND w.professional_id IS NOT DISTINCT FROM p_professional_id
      AND w.date_from=v_from AND w.date_until=v_until
      AND w.time_from IS NOT DISTINCT FROM p_time_from
      AND w.time_until IS NOT DISTINCT FROM p_time_until
      AND w.status IN ('WAITING','OFFERED')
    ORDER BY w.created_at DESC LIMIT 1 FOR UPDATE;

    IF FOUND THEN
      RETURN jsonb_build_object('ok',true,'code','WAITLIST_ALREADY_ACTIVE','waitlist_id',v_existing.id,'status',v_existing.status);
    END IF;

    BEGIN
      INSERT INTO core.waitlist_subscriptions_v2(
        business_id,customer_id,conversation_id,service_id,professional_id,date_from,date_until,time_from,time_until,source
      ) VALUES (
        p_business_id,p_customer_id,p_conversation_id,p_service_id,p_professional_id,v_from,v_until,p_time_from,p_time_until,coalesce(p_source,'ASSISTANT')
      ) RETURNING * INTO v_row;
    EXCEPTION WHEN unique_violation THEN
      SELECT * INTO v_row FROM core.waitlist_subscriptions_v2 w
      WHERE w.business_id=p_business_id AND w.customer_id=p_customer_id AND w.service_id=p_service_id
        AND w.professional_id IS NOT DISTINCT FROM p_professional_id
        AND w.date_from=v_from AND w.date_until=v_until
        AND w.time_from IS NOT DISTINCT FROM p_time_from AND w.time_until IS NOT DISTINCT FROM p_time_until
        AND w.status IN ('WAITING','OFFERED') ORDER BY w.created_at DESC LIMIT 1;
    END;

    UPDATE core.conversations
    SET current_intent='JOIN_WAITLIST',pending_action=NULL,
        context=jsonb_set(coalesce(context,'{}'::jsonb),'{waitlist}',jsonb_build_object('waitlist_id',v_row.id),true)
    WHERE business_id=p_business_id AND id=p_conversation_id;

    RETURN jsonb_build_object(
      'ok',true,'code','WAITLIST_JOINED','result_type','WAITLIST_CONFIRMATION',
      'waitlist',jsonb_build_object('waitlist_id',v_row.id,'status',v_row.status,'date_from',v_row.date_from,'date_until',v_row.date_until)
    );
END;
$function$;

CREATE OR REPLACE FUNCTION core.leave_waitlist_v2(
    p_business_id UUID,p_customer_id UUID,p_waitlist_id UUID DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
VOLATILE
AS $function$
DECLARE v_count INTEGER;
BEGIN
    UPDATE core.waitlist_subscriptions_v2
    SET status='CANCELLED',updated_at=now()
    WHERE business_id=p_business_id AND customer_id=p_customer_id
      AND status IN ('WAITING','OFFERED')
      AND (p_waitlist_id IS NULL OR id=p_waitlist_id);
    GET DIAGNOSTICS v_count=ROW_COUNT;
    RETURN jsonb_build_object('ok',true,'code',CASE WHEN v_count>0 THEN 'WAITLIST_LEFT' ELSE 'WAITLIST_NOT_ACTIVE' END,'cancelled',v_count);
END;
$function$;

CREATE OR REPLACE FUNCTION core.process_waitlist_automation_v2(p_limit INTEGER,p_execution_ref TEXT)
RETURNS JSONB
LANGUAGE plpgsql
VOLATILE
AS $function$
DECLARE
    r RECORD;
    v_offer JSONB;
    v_count INTEGER:=0;
    v_offered INTEGER:=0;
    v_expired INTEGER:=0;
    v_result JSONB;
    v_text TEXT;
    v_limit INTEGER;
    v_ttl INTEGER;
BEGIN
    UPDATE core.waitlist_subscriptions_v2
    SET status='WAITING',last_slot_offer_id=NULL,offer_expires_at=NULL,updated_at=now()
    WHERE status='OFFERED' AND offer_expires_at IS NOT NULL AND offer_expires_at<=now();

    UPDATE core.waitlist_subscriptions_v2 w
    SET status='EXPIRED',updated_at=now()
    FROM core.businesses b
    WHERE w.business_id=b.id AND w.status IN ('WAITING','OFFERED')
      AND w.date_until < (now() AT TIME ZONE b.timezone)::date;
    GET DIAGNOSTICS v_expired=ROW_COUNT;

    FOR r IN
      SELECT w.*,bs.max_slots_per_offer,bs.waitlist_offer_ttl_minutes,b.timezone
      FROM core.waitlist_subscriptions_v2 w
      JOIN core.business_settings bs ON bs.business_id=w.business_id AND bs.waitlist_enabled=true
      JOIN core.businesses b ON b.id=w.business_id
      JOIN core.conversations c ON c.business_id=w.business_id AND c.id=w.conversation_id AND c.status='OPEN'
      WHERE w.status='WAITING'
        AND w.date_until >= (now() AT TIME ZONE b.timezone)::date
        AND (c.pending_action IS NULL OR c.pending_action IN ('JOIN_WAITLIST','WAITLIST'))
      ORDER BY w.created_at
      LIMIT greatest(1,least(coalesce(p_limit,250),1000))
      FOR UPDATE OF w SKIP LOCKED
    LOOP
      v_limit:=greatest(1,least(coalesce(r.max_slots_per_offer,5),10));
      v_ttl:=greatest(1,least(coalesce(r.waitlist_offer_ttl_minutes,10),120));
      UPDATE core.waitlist_subscriptions_v2 SET last_checked_at=now(),updated_at=now() WHERE id=r.id;

      v_offer:=core.create_slot_offer(
        r.business_id,r.conversation_id,ARRAY[r.service_id],r.date_from,r.date_until,
        r.professional_id,r.time_from,r.time_until,v_limit,v_ttl
      );

      IF coalesce((v_offer->>'ok')::boolean,false) AND coalesce((v_offer->>'count')::integer,0)>0 THEN
        v_text:='Abriu um horário que combina com o que você pediu na lista de espera. Escolha uma opção abaixo:';
        v_result:=core.queue_outbound_notification_v3(
          r.business_id,r.customer_id,'WAITLIST_SLOT_OFFER',
          jsonb_build_object('text',v_text,'metadata',jsonb_build_object('waitlist_id',r.id)),
          'WAITLIST_OFFER:'||r.id||':'||(v_offer->>'slot_offer_id'),p_execution_ref,
          jsonb_build_object('result',v_offer),'SLOT_OPTIONS'
        );
        IF coalesce((v_result->>'ok')::boolean,false) THEN
          UPDATE core.waitlist_subscriptions_v2
          SET status='OFFERED',last_slot_offer_id=(v_offer->>'slot_offer_id')::uuid,
              offer_expires_at=nullif(v_offer->>'expires_at','')::timestamptz,updated_at=now()
          WHERE id=r.id;
          v_offered:=v_offered+1;
        END IF;
      END IF;
      v_count:=v_count+1;
    END LOOP;

    RETURN jsonb_build_object('ok',true,'checked',v_count,'offered',v_offered,'expired',v_expired);
END;
$function$;

CREATE OR REPLACE FUNCTION core.process_waitlist_automation_v1(p_limit INTEGER,p_execution_ref TEXT)
RETURNS JSONB LANGUAGE sql VOLATILE AS $function$
SELECT core.process_waitlist_automation_v2(p_limit,p_execution_ref);
$function$;

CREATE OR REPLACE FUNCTION core.mark_waitlist_booked_from_offer_v1(
  p_business_id UUID,p_customer_id UUID,p_slot_offer_id UUID,p_appointment_id UUID
)
RETURNS JSONB LANGUAGE plpgsql VOLATILE AS $function$
DECLARE v_count INTEGER;
BEGIN
 UPDATE core.waitlist_subscriptions_v2
 SET status='BOOKED',metadata=metadata||jsonb_build_object('appointment_id',p_appointment_id),updated_at=now()
 WHERE business_id=p_business_id AND customer_id=p_customer_id
   AND last_slot_offer_id=p_slot_offer_id AND status='OFFERED';
 GET DIAGNOSTICS v_count=ROW_COUNT;
 RETURN jsonb_build_object('ok',true,'updated',v_count);
END;
$function$;
