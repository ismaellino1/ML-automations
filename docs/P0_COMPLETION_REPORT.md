# P0 Completion Report

Data: 2026-09-19
Repositório: `ismaellino1/ML-automations` (branch `main`)
Commits: `cf79678`, `489a3a9`, `3fb3fc2`

## 0. Repository Safety Gate (pré-requisito, executado primeiro)

- Diretório de trabalho original: `/home/user/urca-mirror`, remote `https://github.com/ismaellino1/urca-mirror`.
- `git ls-remote origin` retornou **vazio** — este repositório nunca teve um único commit, em nenhum branch. `search_repositories` para `user:ismaellino1` não o lista. Não há nenhuma evidência de que seja um repositório dedicado à ML Automações.
- Único repositório da conta cujo nome corresponde ao produto: `ismaellino1/ML-automations` (criado 2025-06-29, `default_branch: main`, público, `can_push: true`). Também estava vazio no início desta sessão (`git ls-remote` sem refs) — mas é o candidato correto por nome, unicidade e ausência de qualquer alternativa.
- **Decisão**: não escrever em `urca-mirror`. Usar `ismaellino1/ML-automations` como workspace canônico, preservando o handoff original imutável em `reference/handoff/`. Documentado em `README.md` e no primeiro commit (`cf79678`... na verdade o commit de bootstrap, ver histórico completo do branch).
- Nenhuma ação foi tomada em PROD ou STAGING em nenhum momento deste ciclo.

## 1. Problemas encontrados (resumo, ver `docs/AUDIT/PHASE_A.md` para o detalhe completo)

| ID | Severidade | Descrição curta |
|---|---|---|
| D.1 / RISK-001 | CRITICAL | `ingest_whatsapp_webhook_final` perdia audit trail + dedupe em qualquer erro de processamento |
| D.2 / RISK-002 | CRITICAL | Migration 051 colidia com o contrato real de `core.message_delivery_events` (027) |
| D.4 / RISK-004 | CRITICAL | Control plane completo (`_final`) era código morto; entry points chamavam `_v2` (3 ações) |
| D.5 / RISK-005 | CRITICAL | Observabilidade global quebrada por mismatch de assinatura (1 arg JSONB vs 8 posicionais) |
| **RISK-017** | **CRITICAL (novo)** | `enqueue_integration_job_v1`'s `p_priority SMALLINT` rejeitava literal inteiro sem cast em **todos os 12 call sites reais** — descoberto só ao executar a cadeia real contra Postgres |
| D.7 / RISK-007 | HIGH | `lease_owner`/`worker_ref` perdido em toda conclusão bem-sucedida de job |
| D.8 / RISK-008 | HIGH | `businesses.code` (inexistente) vs `business_code` no arquivo canônico do pacote |
| D.13 / RISK-013 | MEDIUM | Testes sem asserção real, 0/15 cenários do TEST_MATRIX automatizados |

Achados ainda abertos e bloqueados (não são bugs corrigíveis sem mais informação — ver seção 6): D.3, D.6, D.9, D.10 (funções/tabelas sem fonte neste pacote).

## 2. Correções aplicadas

- **P0.1** — Removida a `CREATE TABLE core.message_delivery_events` colidente de 051. `core.ingest_whatsapp_delivery_status_v1` reescrita para resolver o tenant via `core.business_channels` e delegar inteiramente a `core.apply_message_delivery_status`/`core.bind_outbound_external_message` (027, intocadas) — preservando idempotência (`event_key`), replay de receipts pendentes, monotonicidade e tenant safety herdados do contrato real, não reimplementados.
- **P0.2** — `ingest_whatsapp_webhook_final` reescrita com um bloco `BEGIN/EXCEPTION` aninhado para o processamento, para que uma falha downstream não desfaça o `INSERT` de auditoria/dedupe já commitado. A função não faz mais `RAISE` — retorna `{ok:false,...}` estruturado, compatível com o que o único chamador (nó n8n "03 - ASSERT INGEST") já esperava.
- **P0.3** — Corrigida a chamada do workflow n8n `99_ml_observability.json` para `record_automation_incident_v1` (era 1 arg JSONB, agora 8 posicionais corretos), com extração de `severity`/`error_code` enriquecida no node normalizador.
- **P0.4** — `complete_integration_job_v1` corrigida para capturar `lease_owner` via `SELECT ... FOR UPDATE` antes do `UPDATE` que o zera, igual ao padrão já correto de `fail_integration_job_v1`.
- **P0.5** — `ingest_whatsapp_event_v1` (048) corrigida para ler `business_code` em vez de `code`. Arquivo canônico único, sem duplicata `_fixed`.
- **P0.7** — `control-api/index.ts` e `n8n/08_ml_control_plane.json` migrados de `execute_control_plane_action_v2` para `execute_control_plane_action_final` (055), após auditoria de RBAC/payload/idempotência/compatibilidade com frontend. `_v2` mantida como helper interno (usada por `_final` para 2 ações).
- **P0.8** — Suite de testes real criada (ver seção 4). Durante sua construção, **descoberto e corrigido** o RISK-017 (ver acima) — `p_priority` ampliado de `SMALLINT` para `INTEGER` em `enqueue_integration_job_v1` (043), corrigindo os 12 call sites de uma vez na fonte, sem tocar cada um individualmente.

## 3. Arquivos e migrations alterados

| Arquivo | Mudança |
|---|---|
| `supabase/migrations/043_prod_job_queue.sql` | P0.4 (lease_owner) + RISK-017 (p_priority INTEGER) |
| `supabase/migrations/048_runtime_v5_adapters.sql` | P0.5 (business_code) |
| `supabase/migrations/051_whatsapp_calendar_hardening.sql` | P0.1 (contrato de delivery status) |
| `supabase/migrations/055_control_plane_final.sql` | P0.7 (header de decisão, sem mudança funcional) |
| `supabase/migrations/056_whatsapp_webhook_final.sql` | P0.2 (atomicidade) |
| `n8n/01_ml_inbound_gateway.json` | P0.1 (canal em eventos DELIVERY_STATUS) |
| `n8n/08_ml_control_plane.json` | P0.7 (chamada para `_final`) |
| `n8n/99_ml_observability.json` | P0.3 (assinatura corrigida) |
| `supabase/functions/control-api/index.ts` | P0.7 (RPC para `_final`) |

Nenhuma migration histórica (006–042) foi tocada. Nenhuma migration foi reescrita silenciosamente — cada correção tem um comentário de cabeçalho explicando o quê, por quê e onde está o teste de regressão.

## 4. Testes criados e resultados

Infraestrutura: `supabase/tests/local_harness/` — Postgres 16 + pgTAP reais rodando localmente nesta sessão (não simulado, não teórico). `run_local_harness.sh` recria o banco do zero e aplica a cadeia real: fixture sintética mínima (não-migration, documentada) → **007, 027 (reais, intocadas)** → **043–052, 055–057 (reais, com as correções P0 aplicadas)** → toda a suite `supabase/tests/p0/*.sql`.

| Arquivo | Assertions | Resultado |
|---|---|---|
| `001_p0_1_message_delivery_status.sql` | 20 | ✅ 20/20 |
| `002_p0_2_webhook_atomicity.sql` | 11 | ✅ 11/11 |
| `002b_concurrency_check.sh` (real, 2 conexões) | 1 (binário) | ✅ PASS — zero overlap |
| `003_p0_3_observability.sql` | 11 | ✅ 11/11 |
| `004_p0_4_job_worker_ref.sql` | 4 | ✅ 4/4 |
| `005_p0_5_business_code.sql` | 3 | ✅ 3/3 |
| `007_p0_7_control_plane.sql` | 12 | ✅ 12/12 |
| `008_p0_8_job_queue_resilience.sql` | 9 | ✅ 9/9 |
| `008b_concurrent_claim_check.sh` (real, 2 conexões) | 1 (binário) | ✅ PASS — zero overlap, 5/5 jobs claimados |
| `009_p0_8_campaigns_and_media.sql` | 8 | ✅ 8/8 |
| **Total pgTAP** | **78** | **✅ 78/78** |

Cada correção seguiu o gate exigido: reprodução real (capturada, ex.: `/tmp/p0_1_before.log` mostrando o erro exato antes da correção) → teste falhando → correção → teste passando → testes de contrato (`has_column`/`hasnt_column` em 001) → regressão (suite completa recomeça do zero a cada execução) → revisão adversarial (tentativas de duplicar webhook, corrida real de 2 conexões, tenant cruzado, RBAC negado).

Cobertura de `docs/TEST_MATRIX.md`: 8 de 15 cenários aplicáveis ao escopo do P0 têm teste real executado; 6 de 15 exigem o domínio de appointments (fora do escopo de qualquer correção P0) e são explicitamente marcados como tal, não ocultados. Ver `docs/P0_TEST_MATRIX_COVERAGE.md` para o mapeamento completo item a item.

## 5. Riscos restantes

Ver `RISK_REGISTER.md` atualizado. Resumo: RISK-001, 002, 004 (control plane), 005, 007, 008, 013, 017 → **RESOLVED**. RISK-003, 006, 009, 010 → **OPEN — BLOCKED** (aguardando introspecção). RISK-011, 012, 014, 015, 016, 018 → **OPEN**, atribuídos a P1.

## 6. Itens não provados / bloqueados

**P0.6 não foi concluído** — está genuinamente bloqueado, não pulado. Esta sessão não tem credenciais de banco de STAGING. O script `supabase/scripts/introspection/00_readonly_contract_check.sql` (100% somente leitura) foi escrito e está pronto, registrado como **AÇÃO-001** em `MANUAL_ACTIONS_FOR_ISMAEL.md`, aguardando você executá-lo e devolver a saída completa.

Itens que continuam `UNVERIFIED` até essa introspecção (não reconstruídos por suposição, conforme instruído):

- `core.finalize_assistant_turn`
- `core.select_and_confirm_slot_offer_option_v3`
- `core.appointment_calendar_syncs` (tabela) + `prepare/complete/fail_appointment_calendar_sync`
- `core.prepare_assistant_context`
- `core.run_housekeeping_v2`
- `core.set_updated_at`
- Forma real atual de `core.customer_preferences` e `core.customer_engagement_profiles`
- Origem de `business_settings.rescheduling_enabled`/`rescheduling_notice_minutes`
- Confirmação de `UNIQUE(business_id,id)` em `core.messages` (evidência forte via leitura direta de 007 sugere que **não existe** — ver `docs/AUDIT/PHASE_A.md` D.2 — mas a introspecção real é o critério final)

Nenhuma dessas lacunas bloqueou P0.1–P0.5, P0.7 ou P0.8: nenhuma correção aplicada depende dessas funções/tabelas (a correção de P0.1, em particular, foi desenhada deliberadamente para reutilizar o contrato de 027 e evitar precisar saber a forma real de `core.messages`).

## 7. Schema delta

Resumo por migration (delta em relação ao que já existia em cada arquivo, não em relação a 001–042):

- **043**: `p_priority` de `SMALLINT` para `INTEGER` em `enqueue_integration_job_v1` (assinatura de função apenas; `core.integration_jobs.priority` continua `SMALLINT`, sem migration de coluna necessária). `complete_integration_job_v1` reescrita internamente (mesma assinatura/retorno).
- **048**: nenhuma mudança de schema — só a expressão `SELECT business_code` em vez de `SELECT code` dentro de `ingest_whatsapp_event_v1`.
- **051**: **remove** a `CREATE TABLE core.message_delivery_events` e seu índice que colidiam com 027 (nunca chegaram a criar nada real, já que 027 sempre existia primeiro — este delta é sobre o texto da migration, não sobre um schema já aplicado em lugar nenhum). `ingest_whatsapp_delivery_status_v1` ganha 2 parâmetros novos (`p_external_channel_id`, `p_provider`) e muda de posição os demais.
- **055**: nenhuma mudança de schema — apenas comentário de cabeçalho documentando a decisão P0.7.
- **056**: nenhuma mudança de schema — lógica de exceção reestruturada dentro da função.

Nenhuma tabela nova, nenhuma coluna nova, nenhum índice novo foi introduzido por este ciclo P0. Todas as correções são internas a corpos de função ou a comentários/renomeações organizacionais de nós n8n.

## 8. Compatibilidade com 001–042

Comprovada de forma direta e real: o harness local aplica as **migrations históricas reais recuperadas** (007, 027, sem nenhuma modificação) imediatamente antes das migrations 043+ corrigidas, e toda a suite passa. Isso prova que as correções P0 são compatíveis com o contrato real de 007/027 — de fato, a correção de P0.1 *depende* inteiramente desse contrato (reutiliza `apply_message_delivery_status`/`bind_outbound_external_message` de 027 sem alterá-las).

Não testado localmente (exige o schema completo de appointments, fora do escopo do P0 — ver `run_local_harness.sh`): compatibilidade com 006, 013, 015–019, 026, 029, 035–042. Nenhuma correção P0 toca essas migrations nem qualquer função que elas definem, então o risco de incompatibilidade introduzida é baixo, mas não foi provado empiricamente como o restante foi.

## 9. Status de STAGING

**Nada foi aplicado em STAGING.** Todas as correções existem apenas neste repositório (`ML-automations`, branch `main`) e foram validadas contra um Postgres local efêmero criado nesta sessão (descartado ao final). Aplicar em STAGING é uma ação subsequente, condicionada à sua autorização, e deve seguir a ordem: introspecção real (AÇÃO-001) → revisão desta correção à luz dos resultados reais → aplicação em STAGING → nova rodada de validação contra STAGING real → só então considerar produção (que continua proibida neste ciclo).

## 10. GO / NO-GO para P1

**GO condicional.**

- **GO** para iniciar trabalho P1 que não depende dos itens bloqueados do P0.6 — isso inclui a maior parte do hardening de Growth/Messaging (dead-end n8n switches, reconciliação MODIFIED/EXPERIMENTAL de calendário, wiring da política de IA) e a preparação do vertical Food (P2 no roadmap), já que nada em Food toca `finalize_assistant_turn`/`select_and_confirm_slot_offer_option_v3`/`appointment_calendar_syncs`.
- **NO-GO** para qualquer trabalho que assuma ou modifique o motor de Appointments (reschedule/rebook/slot-offer) até o AÇÃO-001 retornar — reescrever ou até auditar mais a fundo essas áreas sem a introspecção real seria exatamente o tipo de "reconstrução por suposição" que este processo proíbe.
- Recomendo fortemente que você rode a AÇÃO-001 o quanto antes: é 100% somente leitura, leva minutos, e desbloqueia tanto P0.6 quanto boa parte do trabalho de Appointments em P1.
