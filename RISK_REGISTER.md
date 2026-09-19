# Risk Register

Mantido continuamente. Cada risco: ID, severidade, probabilidade, impacto, owner, mitigação,
status, evidência.

| ID | Severidade | Descrição | Evidência | Mitigação | Status |
|---|---|---|---|---|---|
| RISK-001 | CRITICAL | Webhook exception handling perde audit trail e proteção de dedupe em qualquer erro (D.1) | `supabase/migrations/056_whatsapp_webhook_final.sql` | P0.2 — corrigido, testado (11 assertions + real 2-connection race) | **RESOLVED** |
| RISK-002 | CRITICAL | Migration 051 colide com contrato real de `message_delivery_events` (D.2) | `supabase/migrations/051_whatsapp_calendar_hardening.sql`, `027_assistant_messaging_engine.sql` | P0.1 — corrigido, testado (20 assertions) | **RESOLVED** |
| RISK-003 | CRITICAL | `core.finalize_assistant_turn` sem fonte neste repositório (D.3) | Chamada por todos os workflows n8n e por 048/054 | P0.6 — bloqueado em introspecção de STAGING (ver `MANUAL_ACTIONS_FOR_ISMAEL.md` AÇÃO-001) | OPEN — BLOCKED |
| RISK-004 | CRITICAL | Control plane completo (`_final`) era código morto; console 0% funcional (D.4) | `supabase/functions/control-api/index.ts`, `n8n/08_ml_control_plane.json` | P0.7 — entry points migrados para `_final`, auditado (RBAC/payload/idempotência/frontend), testado (12 assertions). Frontend em si continua 0% funcional (ver RISK-012, P1). | **RESOLVED (control plane)** / console UI ainda P1 |
| RISK-005 | CRITICAL | Pipeline de observabilidade quebrado por mismatch de assinatura (D.5) | `n8n/99_ml_observability.json` vs `supabase/migrations/049_observability.sql` | P0.3 — corrigido, testado (11 assertions cobrindo Meta/Calendar/SQL/LLM/genérico) | **RESOLVED** |
| RISK-006 | HIGH | `core.run_housekeeping_v2` sem fonte (D.6) | `n8n/07_ml_automation_scheduler.json:116` | P0.6 — bloqueado em introspecção | OPEN — BLOCKED |
| RISK-007 | HIGH | `lease_owner`/`worker_ref` perdido em toda conclusão bem-sucedida de job (D.7) | `supabase/migrations/043_prod_job_queue.sql` | P0.4 — corrigido, testado (4 assertions) | **RESOLVED** |
| RISK-008 | HIGH | `businesses.code` vs `business_code` no arquivo canônico do pacote (D.8) | `supabase/migrations/048_runtime_v5_adapters.sql` | P0.5 — corrigido, testado (3 assertions, prova E2E de ingestão) | **RESOLVED** |
| RISK-009 | HIGH | `core.select_and_confirm_slot_offer_option_v3` sem fonte (D.9) | `038_cancelled_appointment_rebooking.sql`, `042_active_appointment_rescheduling.sql` | P0.6 — bloqueado em introspecção | OPEN — BLOCKED |
| RISK-010 | HIGH | `core.appointment_calendar_syncs` + funções de ciclo de vida sem fonte (D.10) | `035`, `042`, n8n nós 14/17/18/19/22/23 | P0.6 — bloqueado em introspecção | OPEN — BLOCKED |
| RISK-011 | HIGH (revisado) | Divergência doc/política/código na seleção de modelo de IA (D.11 reclassificado) | `057_ai_runtime_policy_final.sql`, `n8n/03_ml_conversation_worker.json`, `docs/AI_MODEL_POLICY.md` | P1 — a planejar (fiar `get_ai_runtime_policy_v1` nos nós n8n, ou aposentar a tabela) | OPEN |
| RISK-017 | **CRITICAL (novo, descoberto durante P0.8)** | `core.enqueue_integration_job_v1`'s `p_priority SMALLINT` não aceita literal inteiro sem cast em nenhum call site real (12 chamadas em 044/045/048/051/052/054) — toda chamada real falhava em runtime com "function does not exist". Só descoberto executando a cadeia de migrations contra um Postgres real, não por leitura de código. | `supabase/migrations/043_prod_job_queue.sql` (antes da correção); reproduzido isolado em `pg_temp.f(a smallint, b integer)` | P0.8 — corrigido (parâmetro ampliado para INTEGER), testado (78 assertions passando na suite completa) | **RESOLVED** |
| RISK-012 | MEDIUM | Frontend `ml-console` 0% funcional (D.12) | `apps/ml-console/src/pages/*` | P1 | OPEN |
| RISK-013 | MEDIUM | Testes sem asserção real, 0/15 cenários do TEST_MATRIX automatizados (D.13) | (histórico) `supabase/tests/001_job_queue.sql`, `002_security_notes.sql` | P0.8 — 8/15 cenários aplicáveis cobertos com testes reais executados (ver `docs/P0_TEST_MATRIX_COVERAGE.md`); 6/15 fora de escopo do P0 (domínio appointments/IA), 1/15 parcial | **RESOLVED (escopo P0)** |
| RISK-014 | MEDIUM | Vídeo processado sem gate (D.14) | `supabase/functions/media-processor/index.ts:46` | P1 | OPEN |
| RISK-015 | MEDIUM | Switches n8n com ramos de erro não fiados (D.15) | Workflow V3 canônico, múltiplos nós | P1 | OPEN |
| RISK-016 | MEDIUM | Notificação de cancelamento órfã nos 3 workflows V3 (D.16) | nós 24-27, todas as variantes | P1 — decisão pendente | OPEN |
| RISK-018 | LOW (novo, P0.7) | `p_idempotency_key` é exigido mas não deduplicado no nível do dispatcher do control plane — depende das operações subjacentes serem naturalmente idempotentes | `supabase/migrations/055_control_plane_final.sql` (cabeçalho) | P1 — avaliar cache de replay por idempotency_key se necessário | OPEN |

Itens LOW (D.17–D.21) rastreados em `KNOWN_LIMITATIONS.md`, não neste registro de risco.
