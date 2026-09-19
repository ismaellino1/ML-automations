-- BASE_001_042_CONTRACT.sql
-- Read-only preflight. It intentionally fails fast when the verified V3 base is not present.

DO $preflight$
DECLARE
    missing TEXT[] := ARRAY[]::TEXT[];
BEGIN
    IF to_regclass('core.businesses') IS NULL THEN missing := array_append(missing,'core.businesses'); END IF;
    IF to_regclass('core.business_settings') IS NULL THEN missing := array_append(missing,'core.business_settings'); END IF;
    IF to_regclass('core.business_channels') IS NULL THEN missing := array_append(missing,'core.business_channels'); END IF;
    IF to_regclass('core.customers') IS NULL THEN missing := array_append(missing,'core.customers'); END IF;
    IF to_regclass('core.customer_channels') IS NULL THEN missing := array_append(missing,'core.customer_channels'); END IF;
    IF to_regclass('core.conversations') IS NULL THEN missing := array_append(missing,'core.conversations'); END IF;
    IF to_regclass('core.messages') IS NULL THEN missing := array_append(missing,'core.messages'); END IF;
    IF to_regclass('core.services') IS NULL THEN missing := array_append(missing,'core.services'); END IF;
    IF to_regclass('core.professionals') IS NULL THEN missing := array_append(missing,'core.professionals'); END IF;
    IF to_regclass('core.professional_services') IS NULL THEN missing := array_append(missing,'core.professional_services'); END IF;
    IF to_regclass('core.appointments') IS NULL THEN missing := array_append(missing,'core.appointments'); END IF;
    IF to_regclass('core.appointment_items') IS NULL THEN missing := array_append(missing,'core.appointment_items'); END IF;
    IF to_regclass('core.slot_offers') IS NULL THEN missing := array_append(missing,'core.slot_offers'); END IF;
    IF to_regclass('core.appointment_calendar_syncs') IS NULL THEN missing := array_append(missing,'core.appointment_calendar_syncs'); END IF;

    IF to_regprocedure('core.prepare_assistant_turn(text,text,text,text,text,text,text,text,jsonb,timestamptz,integer)') IS NULL
       THEN missing := array_append(missing,'core.prepare_assistant_turn'); END IF;
    IF to_regprocedure('core.execute_assistant_action_v3(uuid,uuid,uuid,text,text,text,jsonb)') IS NULL
       THEN missing := array_append(missing,'core.execute_assistant_action_v3'); END IF;
    IF to_regprocedure('core.finalize_assistant_turn(uuid,uuid,uuid,uuid,text,text,uuid,text,numeric,text,text,text,text,text,text,boolean)') IS NULL
       THEN missing := array_append(missing,'core.finalize_assistant_turn'); END IF;
    IF to_regprocedure('core.prepare_appointment_cancellation_outbound(uuid,uuid)') IS NULL
       THEN missing := array_append(missing,'core.prepare_appointment_cancellation_outbound'); END IF;

    IF cardinality(missing) > 0 THEN
        RAISE EXCEPTION 'ML BASE 001-042 INCOMPLETE. Missing: %', array_to_string(missing, ', ');
    END IF;

    RAISE NOTICE 'ML BASE 001-042 preflight passed.';
END
$preflight$;
