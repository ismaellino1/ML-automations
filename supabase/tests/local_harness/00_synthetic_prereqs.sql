-- ============================================================================
-- NOT A MIGRATION. Do not apply to STAGING or PROD.
-- ============================================================================
--
-- Minimal synthetic stand-in for the objects that migrations 001-005 (and
-- other gaps in 010-012,014,018,020-025,028,030-034,041) are assumed to have
-- created, based on:
--   (a) confirmed real columns from a prior STAGING introspection, for
--       core.businesses / core.business_channels (see
--       reference/handoff/10_DATABASE_REALITY_AND_PATCHES/01_KNOWN_DATABASE_FACTS.md);
--   (b) direct column-usage evidence from the migrations we DO have in full
--       (006, 007, 013, 027, 048, 051, 055...) for the remaining tables.
--
-- Purpose: let the REAL migrations (007, 027, 043-057, unmodified except
-- where a specific P0 fix is under test) apply and run against a real,
-- local, throwaway Postgres instance, so P0 fixes can be proven against an
-- actual engine instead of argued about in the abstract.
--
-- This file intentionally does NOT implement business logic (RLS, triggers
-- beyond the one bare minimum needed for 007's own triggers to attach,
-- validation, appointments/services/professionals) - only what's structurally
-- required for the messaging chain (006 is NOT required for P0.1-P0.4/P0.8's
-- messaging-focused tests and is intentionally NOT part of this fixture).
--
-- If a real STAGING introspection (see supabase/scripts/introspection/)
-- later shows a real column this fixture is missing and a test needs it,
-- extend this file - never silently assume behavior this fixture doesn't
-- structurally enforce.
-- ============================================================================

CREATE SCHEMA IF NOT EXISTS core;
CREATE SCHEMA IF NOT EXISTS private;

CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- Supabase provisions these roles automatically on every project; a vanilla
-- local Postgres does not, so migrations that GRANT/REVOKE against them
-- (050_security_rls.sql) need a harmless local stand-in to apply at all.
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN
    CREATE ROLE anon NOLOGIN;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN
    CREATE ROLE authenticated NOLOGIN;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'service_role') THEN
    CREATE ROLE service_role NOLOGIN;
  END IF;
END
$$;

-- Supabase provides auth.uid() (reads the JWT claim of the connected
-- session) as a platform primitive; vanilla Postgres has neither the schema
-- nor the function. Harmless stub returning NULL so RLS-defining migrations
-- (050) apply structurally; actual RLS *behavior* testing against real
-- Supabase auth is out of scope for this local harness.
CREATE SCHEMA IF NOT EXISTS auth;
CREATE OR REPLACE FUNCTION auth.uid() RETURNS UUID LANGUAGE sql STABLE AS $$ SELECT NULL::uuid $$;

-- Every table trigger in the real migrations calls this by name; its
-- implementation is unambiguous (there is only one sane way to write a
-- generic "bump updated_at" trigger), so this is a safe synthetic stand-in
-- even though its real source migration is missing from this package.
CREATE OR REPLACE FUNCTION core.set_updated_at()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END;
$$;

-- --------------------------------------------------------------------------
-- core.businesses — confirmed real columns (see 01_KNOWN_DATABASE_FACTS.md)
-- --------------------------------------------------------------------------
CREATE TABLE core.businesses (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_code TEXT NOT NULL UNIQUE,
  name          TEXT NOT NULL,
  timezone      TEXT NOT NULL DEFAULT 'America/Sao_Paulo',
  locale        TEXT NOT NULL DEFAULT 'pt-BR',
  status        TEXT NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE','SUSPENDED','ARCHIVED')),
  plan_code     TEXT,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- --------------------------------------------------------------------------
-- core.business_settings — minimal: only columns actually referenced by the
-- messaging chain (027) and the overlay (052) reminder/reschedule reads we
-- exercise. NOT a claim about the full real table shape.
-- --------------------------------------------------------------------------
CREATE TABLE core.business_settings (
  business_id                       UUID PRIMARY KEY REFERENCES core.businesses(id) ON DELETE CASCADE,
  conversation_idle_timeout_minutes INTEGER NOT NULL DEFAULT 1440,
  reminders_enabled                 BOOLEAN NOT NULL DEFAULT true,
  reminder_first_hours_before       INTEGER,
  reminder_second_hours_before      INTEGER,
  waitlist_enabled                  BOOLEAN NOT NULL DEFAULT false,
  reactivation_enabled              BOOLEAN NOT NULL DEFAULT false,
  cancellation_enabled              BOOLEAN NOT NULL DEFAULT true,
  rescheduling_enabled              BOOLEAN NOT NULL DEFAULT true,
  extra_settings                    JSONB NOT NULL DEFAULT '{}'::jsonb
);

CREATE TABLE core.business_ai_settings (business_id UUID PRIMARY KEY REFERENCES core.businesses(id) ON DELETE CASCADE);
CREATE TABLE core.business_brand_profiles (
  business_id UUID PRIMARY KEY REFERENCES core.businesses(id) ON DELETE CASCADE,
  assistant_name TEXT, brand_personality TEXT, default_treatment TEXT,
  allow_slang BOOLEAN, emoji_max_per_message SMALLINT
);

-- --------------------------------------------------------------------------
-- core.customers / core.customer_channels — minimal, inferred from FK/column
-- usage across 007, 027, 048, 051, 055.
-- --------------------------------------------------------------------------
CREATE TABLE core.customers (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id UUID NOT NULL REFERENCES core.businesses(id) ON DELETE CASCADE,
  name        TEXT NOT NULL,
  status      TEXT NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE','ARCHIVED')),
  notes       TEXT,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT uq_customers_business_id_id UNIQUE (business_id, id)
);

CREATE TABLE core.customer_channels (
  id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id       UUID NOT NULL REFERENCES core.businesses(id) ON DELETE CASCADE,
  customer_id       UUID NOT NULL,
  channel_type      TEXT NOT NULL,
  provider          TEXT NOT NULL,
  external_user_id  TEXT NOT NULL,
  is_primary        BOOLEAN NOT NULL DEFAULT true,
  active            BOOLEAN NOT NULL DEFAULT true,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT fk_customer_channels_customer
    FOREIGN KEY (business_id, customer_id) REFERENCES core.customers(business_id, id) ON DELETE CASCADE
);

CREATE TABLE core.customer_preferences (
  business_id           UUID NOT NULL REFERENCES core.businesses(id) ON DELETE CASCADE,
  customer_id           UUID NOT NULL,
  marketing_opt_in      BOOLEAN NOT NULL DEFAULT true,
  reminders_enabled     BOOLEAN NOT NULL DEFAULT true,
  reactivation_opt_in   BOOLEAN NOT NULL DEFAULT true,
  updated_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (business_id, customer_id)
);

CREATE TABLE core.customer_engagement_profiles (
  business_id               UUID NOT NULL REFERENCES core.businesses(id) ON DELETE CASCADE,
  customer_id               UUID NOT NULL,
  completed_total            INTEGER NOT NULL DEFAULT 0,
  cancelled_total             INTEGER NOT NULL DEFAULT 0,
  no_show_total                INTEGER NOT NULL DEFAULT 0,
  is_recurring                 BOOLEAN NOT NULL DEFAULT false,
  interval_confidence           NUMERIC NOT NULL DEFAULT 0,
  next_expected_at              TIMESTAMPTZ,
  last_completed_at             TIMESTAMPTZ,
  last_reactivation_at          TIMESTAMPTZ,
  reactivation_eligible          BOOLEAN NOT NULL DEFAULT false,
  reactivation_suppressed_until  TIMESTAMPTZ,
  updated_at                    TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (business_id, customer_id)
);
