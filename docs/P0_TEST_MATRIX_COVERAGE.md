# TEST_MATRIX.md coverage (P0.8)

Maps each of the 15 scenarios in `docs/TEST_MATRIX.md` to real, executed test evidence.
"Applicable" per the approved P0 plan means: in scope for what P0 actually touches
(messaging, webhooks, job queue, observability, control plane). Appointments-domain and
AI-behavior scenarios are honestly marked out of scope here — not silently dropped —
because no P0 fix touches migrations 006-042 or the AI orchestrator's own behavior.

| # | Scenario | Status | Evidence |
|---|---|---|---|
| 1 | Texto normal, erro ortográfico, gíria, idioma misto | **OUT OF SCOPE for P0** | AI/NLU robustness question, not a P0 code path. Belongs to a future AI Evaluation harness (P1+, per the master prompt's own AI Evaluation section) with a labeled dataset, not a pgTAP test. |
| 2 | Slot offer: clique válido, antigo, duplicado | **OUT OF SCOPE for P0** | Appointments domain (019/026/042), untouched by any P0 fix. Needs the full appointments-domain schema (006,013,015-019,026,029,035-042) as a fixture - explicitly deferred to a P1 integration harness (see `supabase/tests/local_harness/run_local_harness.sh`'s own note). |
| 3 | Cancelamento pelo cliente/profissional/empresa | **OUT OF SCOPE for P0** | Appointments domain (035). Same reason as #2. |
| 4 | Reschedule ativo: DELETE+CREATE | **OUT OF SCOPE for P0** | Appointments domain (042). Same reason as #2. |
| 5 | Rebook cancelado | **OUT OF SCOPE for P0** | Appointments domain (038/039/040). Same reason as #2. |
| 6 | Áudio, imagem, documento, vídeo, mídia corrompida | **PARTIAL - mechanics covered** | `supabase/tests/p0/009_p0_8_campaigns_and_media.sql` proves the job-queue mechanics (claim -> complete triggers a follow-up CONVERSATION_TURN job; claim -> fail retries). The actual AI transcription/vision *quality* across media types is an external-provider behavior question this local harness cannot exercise (no real OpenAI/Meta calls) - real coverage needs E2E against STAGING providers (P1). |
| 7 | Promoção: vigente, expirada, opt-out, frequência | **COVERED** | `supabase/tests/p0/009_p0_8_campaigns_and_media.sql` - opted-in customer is ELIGIBLE, opted-out is SUPPRESSED (MARKETING_OPT_OUT), a customer contacted inside the frequency-cap window is SUPPRESSED (FREQUENCY_CAP). |
| 8 | Lembrete antes do horário; nunca após cancelamento | **OUT OF SCOPE for P0** | `enqueue_due_reminders` (052) reads `core.appointments WHERE status='CONFIRMED'` - needs the appointments fixture. Deferred to P1. |
| 9 | Falha Meta, Calendar, OpenAI, Media Processor com retry | **COVERED (job-queue mechanics) + PARTIAL (observability)** | `supabase/tests/p0/008_p0_8_job_queue_resilience.sql` proves the generic retry/backoff/dead-letter mechanics all four providers' workers share. `supabase/tests/p0/003_p0_3_observability.sql` proves each of the four failure classes (Meta/Calendar/SQL/LLM) produces an investigable incident. Real provider-specific failure *behavior* (HTTP semantics, timeouts) needs E2E against STAGING providers (P1). |
| 10 | Duplo webhook idêntico não duplica appointment, mensagem, campanha | **PARTIAL - message dedup covered** | `supabase/tests/p0/002_p0_2_webhook_atomicity.sql` proves message/delivery-event dedup survives duplicate delivery, including after a processing failure (the D.1 defect this P0 cycle fixed). Appointment-level dedup is out of scope (appointments domain, #2-5). Campaign-level dedup is not itself webhook-triggered in this codebase, so this specific phrasing doesn't directly apply beyond what #7 already covers. |
| 11 | Dois workers concorrentes não claimam o mesmo job | **COVERED** | `supabase/tests/p0/008b_concurrent_claim_check.sh` - a real two-connection race for a pool of 5 jobs, zero overlap between what each worker claimed. |
| 12 | RBAC: Employee não executa ações de Manager/Admin | **COVERED** | `supabase/tests/p0/007_p0_7_control_plane.sql` - EMPLOYEE is forbidden from LIST_CUSTOMERS (a MANAGER-only read) and correctly allowed LIST_PRODUCTS (in EMPLOYEE's own allowlist); VIEWER is forbidden from UPSERT_PRODUCT. |
| 13 | Tenant isolation | **COVERED** | `supabase/tests/p0/001_p0_1_message_delivery_status.sql` (messaging: business A/B channels/messages never cross) and `supabase/tests/p0/007_p0_7_control_plane.sql` (control plane: a business-A MANAGER gets FORBIDDEN, writes nothing, when acting on business B). |
| 14 | Dead-letter e replay controlado | **COVERED** | `supabase/tests/p0/008_p0_8_job_queue_resilience.sql` - a job that fails at max_attempts reaches DEAD deterministically, with its full attempt history preserved for investigation. |
| 15 | Recovery após reinício do n8n | **COVERED** | `supabase/tests/p0/008_p0_8_job_queue_resilience.sql` - a job stuck RUNNING behind a simulated expired lease is released by `release_expired_job_leases` and successfully re-claimed by a fresh worker. |

## Summary

- **8 of 15** scenarios have real, executed, passing test coverage within P0's scope (#7, #9-partial, #10-partial, #11, #12, #13, #14, #15), plus #6's mechanics.
- **6 of 15** (#1-5, #8) are honestly out of scope for P0 - they require the appointments domain and/or AI-behavior evaluation, neither of which any P0 fix touches. These are natural P1 items once the appointments-domain integration harness and/or AI evaluation dataset exist.
- Every "COVERED"/"PARTIAL" row above is backed by a real pgTAP or shell test that was actually executed against a live local Postgres 16 + pgTAP instance as part of this P0 cycle (see `supabase/tests/local_harness/`), not just written and assumed correct.
