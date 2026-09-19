Recuperei pela **estrutura real que ficou no banco**. Tem um detalhe: eu não encontrei salvo o texto literal original das duas migrations, então não vou fingir que é byte por byte o mesmo arquivo. Mas dá para reconstruir o SQL praticamente completo a partir das tabelas, defaults e constraints que elas deixaram. A `008` criou a memória/perfil do cliente; a `009` criou as configurações da empresa.  

## 008 — `008_customer_memory_and_...`

Ela é a migration que criou:

- `core.customer_preferences` 
- `core.customer_communication_profiles` 
- `core.customer_engagement_profiles` 

A estrutura atual confirma inclusive preferências de profissional/serviço/período e os perfis de comunicação e recorrência.   

**Importante:** a `011_fix_customer_preference...` veio depois e corrigiu parte das FKs de `customer_preferences`. Então abaixo estou te dando a **versão efetiva/corrigida**, que é a que interessa para reconstruir o projeto hoje.

```
```

```
-- ============================================================
-- ML AUTOMAÇÕES
-- Migration: 008_customer_memory_and_profiles
--
-- Memória operacional e adaptação por cliente.
-- ============================================================


-- ============================================================
-- 1. PREFERÊNCIAS DO CLIENTE
-- ============================================================

CREATE TABLE IF NOT EXISTS core.customer_preferences (

    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    business_id UUID NOT NULL
        REFERENCES core.businesses(id)
        ON DELETE CASCADE,

    customer_id UUID NOT NULL,

    preferred_professional_id UUID,

    preferred_service_id UUID,

    preferred_period VARCHAR(20)
        NOT NULL
        DEFAULT 'ANY'
        CHECK (
            preferred_period IN (
                'ANY',
                'MORNING',
                'AFTERNOON',
                'EVENING'
            )
        ),

    preferred_time_from TIME,

    preferred_time_until TIME,

    reminders_enabled BOOLEAN
        NOT NULL
        DEFAULT TRUE,

    reactivation_opt_in BOOLEAN
        NOT NULL
        DEFAULT FALSE,

    marketing_opt_in BOOLEAN
        NOT NULL
        DEFAULT FALSE,

    created_at TIMESTAMPTZ
        NOT NULL
        DEFAULT NOW(),

    updated_at TIMESTAMPTZ
        NOT NULL
        DEFAULT NOW(),

    CONSTRAINT uq_customer_preferences
        UNIQUE (
            business_id,
            customer_id
        ),

    CONSTRAINT chk_customer_preferred_time
        CHECK (
            preferred_time_from IS NULL
            OR preferred_time_until IS NULL
            OR preferred_time_from < preferred_time_until
        ),

    CONSTRAINT fk_customer_preferences_customer
        FOREIGN KEY (
            business_id,
            customer_id
        )
        REFERENCES core.customers(
            business_id,
            id
        )
        ON DELETE CASCADE,

    CONSTRAINT fk_customer_preferences_professional
        FOREIGN KEY (
            business_id,
            preferred_professional_id
        )
        REFERENCES core.professionals(
            business_id,
            id
        )
        ON DELETE SET NULL (preferred_professional_id),

    CONSTRAINT fk_customer_preferences_service
        FOREIGN KEY (
            business_id,
            preferred_service_id
        )
        REFERENCES core.services(
            business_id,
            id
        )
        ON DELETE SET NULL (preferred_service_id)
);


DROP TRIGGER IF EXISTS
trg_customer_preferences_updated_at
ON core.customer_preferences;

CREATE TRIGGER trg_customer_preferences_updated_at
BEFORE UPDATE ON core.customer_preferences
FOR EACH ROW
EXECUTE FUNCTION core.set_updated_at();


-- ============================================================
-- 2. PERFIL DE COMUNICAÇÃO
-- ============================================================

CREATE TABLE IF NOT EXISTS core.customer_communication_profiles (

    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    business_id UUID NOT NULL
        REFERENCES core.businesses(id)
        ON DELETE CASCADE,

    customer_id UUID NOT NULL,

    formality SMALLINT
        NOT NULL
        DEFAULT 50
        CHECK (
            formality BETWEEN 0 AND 100
        ),

    objectivity SMALLINT
        NOT NULL
        DEFAULT 60
        CHECK (
            objectivity BETWEEN 0 AND 100
        ),

    emoji_usage SMALLINT
        NOT NULL
        DEFAULT 20
        CHECK (
            emoji_usage BETWEEN 0 AND 100
        ),

    slang_usage SMALLINT
        NOT NULL
        DEFAULT 20
        CHECK (
            slang_usage BETWEEN 0 AND 100
        ),

    expansiveness SMALLINT
        NOT NULL
        DEFAULT 40
        CHECK (
            expansiveness BETWEEN 0 AND 100
        ),

    treatment VARCHAR(30)
        NOT NULL
        DEFAULT 'CORDIAL'
        CHECK (
            treatment IN (
                'FORMAL',
                'CORDIAL',
                'INFORMAL',
                'MUITO_INFORMAL'
            )
        ),

    response_length VARCHAR(20)
        NOT NULL
        DEFAULT 'MEDIA'
        CHECK (
            response_length IN (
                'CURTA',
                'MEDIA',
                'DETALHADA'
            )
        ),

    confidence SMALLINT
        NOT NULL
        DEFAULT 0
        CHECK (
            confidence BETWEEN 0 AND 100
        ),

    messages_analyzed INTEGER
        NOT NULL
        DEFAULT 0
        CHECK (
            messages_analyzed >= 0
        ),

    style_notes TEXT,

    created_at TIMESTAMPTZ
        NOT NULL
        DEFAULT NOW(),

    updated_at TIMESTAMPTZ
        NOT NULL
        DEFAULT NOW(),

    CONSTRAINT uq_customer_communication_profile
        UNIQUE (
            business_id,
            customer_id
        ),

    CONSTRAINT fk_customer_communication_profile_customer
        FOREIGN KEY (
            business_id,
            customer_id
        )
        REFERENCES core.customers(
            business_id,
            id
        )
        ON DELETE CASCADE
);


DROP TRIGGER IF EXISTS
trg_customer_communication_profiles_updated_at
ON core.customer_communication_profiles;

CREATE TRIGGER trg_customer_communication_profiles_updated_at
BEFORE UPDATE ON core.customer_communication_profiles
FOR EACH ROW
EXECUTE FUNCTION core.set_updated_at();


-- ============================================================
-- 3. PERFIL DE ENGAJAMENTO / RECORRÊNCIA
-- ============================================================

CREATE TABLE IF NOT EXISTS core.customer_engagement_profiles (

    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    business_id UUID NOT NULL
        REFERENCES core.businesses(id)
        ON DELETE CASCADE,

    customer_id UUID NOT NULL,

    appointments_total INTEGER
        NOT NULL
        DEFAULT 0
        CHECK (
            appointments_total >= 0
        ),

    completed_total INTEGER
        NOT NULL
        DEFAULT 0
        CHECK (
            completed_total >= 0
        ),

    cancelled_total INTEGER
        NOT NULL
        DEFAULT 0
        CHECK (
            cancelled_total >= 0
        ),

    no_show_total INTEGER
        NOT NULL
        DEFAULT 0
        CHECK (
            no_show_total >= 0
        ),

    rescheduled_total INTEGER
        NOT NULL
        DEFAULT 0
        CHECK (
            rescheduled_total >= 0
        ),

    last_appointment_at TIMESTAMPTZ,

    last_completed_at TIMESTAMPTZ,

    average_interval_days NUMERIC
        CHECK (
            average_interval_days IS NULL
            OR average_interval_days >= 0
        ),

    interval_confidence NUMERIC
        NOT NULL
        DEFAULT 0
        CHECK (
            interval_confidence >= 0
            AND interval_confidence <= 1
        ),

    next_expected_at TIMESTAMPTZ,

    is_recurring BOOLEAN
        NOT NULL
        DEFAULT FALSE,

    reactivation_eligible BOOLEAN
        NOT NULL
        DEFAULT FALSE,

    reactivation_suppressed_until TIMESTAMPTZ,

    last_reactivation_at TIMESTAMPTZ,

    created_at TIMESTAMPTZ
        NOT NULL
        DEFAULT NOW(),

    updated_at TIMESTAMPTZ
        NOT NULL
        DEFAULT NOW(),

    CONSTRAINT uq_customer_engagement_profile
        UNIQUE (
            business_id,
            customer_id
        ),

    CONSTRAINT fk_customer_engagement_customer
        FOREIGN KEY (
            business_id,
            customer_id
        )
        REFERENCES core.customers(
            business_id,
            id
        )
        ON DELETE CASCADE
);


DROP TRIGGER IF EXISTS
trg_customer_engagement_profiles_updated_at
ON core.customer_engagement_profiles;

CREATE TRIGGER trg_customer_engagement_profiles_updated_at
BEFORE UPDATE ON core.customer_engagement_profiles
FOR EACH ROW
EXECUTE FUNCTION core.set_updated_at();
```

---

## 009 — `009_business_configuration`

Essa é mais clara. Ela criou:

- `core.business_settings` 
- `core.business_brand_profiles` 
- `core.business_ai_settings` 

O banco atual conserva os defaults: slot de 15 min, hold de 5 min, antecedência de 30 min, horizonte de 60 dias, 5 slots por oferta, cancelamento/remarcação, waitlist, lembretes, reativação e handoff.  As constraints atuais também batem com isso. 

```
```

```
-- ============================================================
-- ML AUTOMAÇÕES
-- Migration: 009_business_configuration
--
-- Configurações operacionais, identidade de atendimento
-- e configuração de IA por estabelecimento.
-- ============================================================


-- ============================================================
-- 1. CONFIGURAÇÕES OPERACIONAIS
-- ============================================================

CREATE TABLE IF NOT EXISTS core.business_settings (

    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    business_id UUID NOT NULL
        REFERENCES core.businesses(id)
        ON DELETE CASCADE,

    slot_interval_minutes INTEGER
        NOT NULL
        DEFAULT 15
        CHECK (
            slot_interval_minutes > 0
            AND slot_interval_minutes <= 120
        ),

    hold_duration_minutes INTEGER
        NOT NULL
        DEFAULT 5
        CHECK (
            hold_duration_minutes > 0
            AND hold_duration_minutes <= 60
        ),

    minimum_booking_notice_minutes INTEGER
        NOT NULL
        DEFAULT 30
        CHECK (
            minimum_booking_notice_minutes >= 0
        ),

    maximum_booking_horizon_days INTEGER
        NOT NULL
        DEFAULT 60
        CHECK (
            maximum_booking_horizon_days > 0
        ),

    max_slots_per_offer INTEGER
        NOT NULL
        DEFAULT 5
        CHECK (
            max_slots_per_offer >= 1
            AND max_slots_per_offer <= 20
        ),

    cancellation_enabled BOOLEAN
        NOT NULL
        DEFAULT TRUE,

    rescheduling_enabled BOOLEAN
        NOT NULL
        DEFAULT TRUE,

    cancellation_notice_minutes INTEGER
        NOT NULL
        DEFAULT 60
        CHECK (
            cancellation_notice_minutes >= 0
        ),

    rescheduling_notice_minutes INTEGER
        NOT NULL
        DEFAULT 60
        CHECK (
            rescheduling_notice_minutes >= 0
        ),

    waitlist_enabled BOOLEAN
        NOT NULL
        DEFAULT TRUE,

    waitlist_offer_ttl_minutes INTEGER
        NOT NULL
        DEFAULT 10
        CHECK (
            waitlist_offer_ttl_minutes > 0
            AND waitlist_offer_ttl_minutes <= 120
        ),

    waitlist_max_candidates INTEGER
        NOT NULL
        DEFAULT 5
        CHECK (
            waitlist_max_candidates > 0
        ),

    reminders_enabled BOOLEAN
        NOT NULL
        DEFAULT TRUE,

    reminder_first_hours_before INTEGER
        DEFAULT 24
        CHECK (
            reminder_first_hours_before IS NULL
            OR reminder_first_hours_before > 0
        ),

    reminder_second_hours_before INTEGER
        DEFAULT 2
        CHECK (
            reminder_second_hours_before IS NULL
            OR reminder_second_hours_before > 0
        ),

    reactivation_enabled BOOLEAN
        NOT NULL
        DEFAULT FALSE,

    reactivation_min_completed INTEGER
        NOT NULL
        DEFAULT 3
        CHECK (
            reactivation_min_completed >= 1
        ),

    reactivation_min_confidence NUMERIC
        NOT NULL
        DEFAULT 0.75
        CHECK (
            reactivation_min_confidence >= 0
            AND reactivation_min_confidence <= 1
        ),

    reactivation_cooldown_days INTEGER
        NOT NULL
        DEFAULT 30
        CHECK (
            reactivation_cooldown_days >= 1
        ),

    human_handoff_enabled BOOLEAN
        NOT NULL
        DEFAULT TRUE,

    max_consecutive_errors_before_handoff INTEGER
        NOT NULL
        DEFAULT 3
        CHECK (
            max_consecutive_errors_before_handoff >= 1
        ),

    conversation_idle_timeout_minutes INTEGER
        NOT NULL
        DEFAULT 1440
        CHECK (
            conversation_idle_timeout_minutes > 0
        ),

    extra_settings JSONB
        NOT NULL
        DEFAULT '{}'::JSONB,

    created_at TIMESTAMPTZ
        NOT NULL
        DEFAULT NOW(),

    updated_at TIMESTAMPTZ
        NOT NULL
        DEFAULT NOW(),

    CONSTRAINT uq_business_settings
        UNIQUE (
            business_id
        )
);


DROP TRIGGER IF EXISTS
trg_business_settings_updated_at
ON core.business_settings;

CREATE TRIGGER trg_business_settings_updated_at
BEFORE UPDATE ON core.business_settings
FOR EACH ROW
EXECUTE FUNCTION core.set_updated_at();


-- ============================================================
-- 2. IDENTIDADE / TOM DA MARCA
-- ============================================================

CREATE TABLE IF NOT EXISTS core.business_brand_profiles (

    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    business_id UUID NOT NULL
        REFERENCES core.businesses(id)
        ON DELETE CASCADE,

    assistant_name VARCHAR(150),

    brand_personality TEXT,

    default_treatment VARCHAR(30)
        NOT NULL
        DEFAULT 'CORDIAL'
        CHECK (
            default_treatment IN (
                'FORMAL',
                'CORDIAL',
                'INFORMAL',
                'MUITO_INFORMAL'
            )
        ),

    minimum_formality SMALLINT
        NOT NULL
        DEFAULT 20
        CHECK (
            minimum_formality BETWEEN 0 AND 100
        ),

    maximum_informality SMALLINT
        NOT NULL
        DEFAULT 80
        CHECK (
            maximum_informality BETWEEN 0 AND 100
        ),

    emoji_max_per_message SMALLINT
        NOT NULL
        DEFAULT 2
        CHECK (
            emoji_max_per_message BETWEEN 0 AND 20
        ),

    use_customer_name BOOLEAN
        NOT NULL
        DEFAULT TRUE,

    allow_slang BOOLEAN
        NOT NULL
        DEFAULT TRUE,

    greeting_text TEXT,

    farewell_text TEXT,

    response_guidelines TEXT,

    created_at TIMESTAMPTZ
        NOT NULL
        DEFAULT NOW(),

    updated_at TIMESTAMPTZ
        NOT NULL
        DEFAULT NOW(),

    CONSTRAINT uq_business_brand_profile
        UNIQUE (
            business_id
        ),

    CONSTRAINT chk_brand_formality_bounds
        CHECK (
            minimum_formality <= maximum_informality
        )
);


DROP TRIGGER IF EXISTS
trg_business_brand_profiles_updated_at
ON core.business_brand_profiles;

CREATE TRIGGER trg_business_brand_profiles_updated_at
BEFORE UPDATE ON core.business_brand_profiles
FOR EACH ROW
EXECUTE FUNCTION core.set_updated_at();


-- ============================================================
-- 3. CONFIGURAÇÕES DE IA
-- ============================================================

CREATE TABLE IF NOT EXISTS core.business_ai_settings (

    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    business_id UUID NOT NULL
        REFERENCES core.businesses(id)
        ON DELETE CASCADE,

    ai_enabled BOOLEAN
        NOT NULL
        DEFAULT TRUE,

    interpretation_model VARCHAR(100),

    response_model VARCHAR(100),

    style_analysis_model VARCHAR(100),

    minimum_intent_confidence NUMERIC
        NOT NULL
        DEFAULT 0.70
        CHECK (
            minimum_intent_confidence >= 0
            AND minimum_intent_confidence <= 1
        ),

    ai_response_generation_enabled BOOLEAN
        NOT NULL
        DEFAULT TRUE,

    style_adaptation_enabled BOOLEAN
        NOT NULL
        DEFAULT TRUE,

    extra_ai_settings JSONB
        NOT NULL
        DEFAULT '{}'::JSONB,

    created_at TIMESTAMPTZ
        NOT NULL
        DEFAULT NOW(),

    updated_at TIMESTAMPTZ
        NOT NULL
        DEFAULT NOW(),

    CONSTRAINT uq_business_ai_settings
        UNIQUE (
            business_id
        )
);


DROP TRIGGER IF EXISTS
trg_business_ai_settings_updated_at
ON core.business_ai_settings;

CREATE TRIGGER trg_business_ai_settings_updated_at
BEFORE UPDATE ON core.business_ai_settings
FOR EACH ROW
EXECUTE FUNCTION core.set_updated_at();
```

A `009` está bem alinhada com a estrutura que ainda existe hoje: `business_brand_profiles` conserva exatamente campos como `assistant_name`, `brand_personality`, limites de formalidade, emojis e textos de saudação/despedida, enquanto `business_ai_settings` mantém os três modelos, confidence mínimo e os switches de IA/adaptação. 