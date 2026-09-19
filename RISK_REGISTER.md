# Risk Register

Mantido continuamente. Cada risco: ID, severidade, probabilidade, impacto, owner, mitigação,
status, evidência.

| ID | Severidade | Descrição | Evidência | Mitigação | Status |
|---|---|---|---|---|---|
| RISK-001 | CRITICAL | Webhook exception handling perde audit trail e proteção de dedupe em qualquer erro (D.1) | `supabase/migrations/056_whatsapp_webhook_final.sql:18-61` | P0.2 — fix em andamento | OPEN |
| RISK-002 | CRITICAL | Migration 051 colide com contrato real de `message_delivery_events` (D.2) | `supabase/migrations/051_whatsapp_calendar_hardening.sql:17-31`, `027_assistant_messaging_engine.sql:37-93` | P0.1 — fix em andamento | OPEN |
| RISK-003 | CRITICAL | `core.finalize_assistant_turn` sem fonte neste repositório (D.3) | Chamada por todos os workflows n8n e por 048/054 | P0.6 — bloqueado em introspecção de STAGING | OPEN — BLOCKED |
| RISK-004 | CRITICAL | Control plane completo (`_final`) é código morto; console 0% funcional (D.4) | `supabase/functions/control-api/index.ts:17`, `n8n/08_ml_control_plane.json` | P0.7 — em andamento | OPEN |
| RISK-005 | CRITICAL | Pipeline de observabilidade quebrado por mismatch de assinatura (D.5) | `n8n/99_ml_observability.json:32` vs `supabase/migrations/049_observability.sql:10-19` | P0.3 — em andamento | OPEN |
| RISK-006 | HIGH | `core.run_housekeeping_v2` sem fonte (D.6) | `n8n/07_ml_automation_scheduler.json:116` | P0.6 — bloqueado em introspecção | OPEN — BLOCKED |
| RISK-007 | HIGH | `lease_owner`/`worker_ref` perdido em toda conclusão bem-sucedida de job (D.7) | `supabase/migrations/043_prod_job_queue.sql:99-104` | P0.4 — em andamento | OPEN |
| RISK-008 | HIGH | `businesses.code` vs `business_code` no arquivo canônico do pacote (D.8) | `supabase/migrations/048_runtime_v5_adapters.sql:63` | P0.5 — em andamento | OPEN |
| RISK-009 | HIGH | `core.select_and_confirm_slot_offer_option_v3` sem fonte (D.9) | `038_cancelled_appointment_rebooking.sql`, `042_active_appointment_rescheduling.sql` | P0.6 — bloqueado em introspecção | OPEN — BLOCKED |
| RISK-010 | HIGH | `core.appointment_calendar_syncs` + funções de ciclo de vida sem fonte (D.10) | `035`, `042`, n8n nós 14/17/18/19/22/23 | P0.6 — bloqueado em introspecção | OPEN — BLOCKED |
| RISK-011 | HIGH (revisado) | Divergência doc/política/código na seleção de modelo de IA (D.11 reclassificado) | `057_ai_runtime_policy_final.sql`, `n8n/03_ml_conversation_worker.json`, `docs/AI_MODEL_POLICY.md` | P1 — a planejar | OPEN |
| RISK-012 | MEDIUM | Frontend `ml-console` 0% funcional (D.12) | `apps/ml-console/src/pages/*` | P1 | OPEN |
| RISK-013 | MEDIUM | Testes sem asserção real, 0/15 cenários do TEST_MATRIX automatizados (D.13) | `supabase/tests/001_job_queue.sql`, `002_security_notes.sql` | P0.8 — em andamento | OPEN |
| RISK-014 | MEDIUM | Vídeo processado sem gate (D.14) | `supabase/functions/media-processor/index.ts:46` | P1 | OPEN |
| RISK-015 | MEDIUM | Switches n8n com ramos de erro não fiados (D.15) | Workflow V3 canônico, múltiplos nós | P1 | OPEN |
| RISK-016 | MEDIUM | Notificação de cancelamento órfã nos 3 workflows V3 (D.16) | nós 24-27, todas as variantes | P1 — decisão pendente | OPEN |

Itens LOW (D.17–D.21) rastreados em `KNOWN_LIMITATIONS.md`, não neste registro de risco.
