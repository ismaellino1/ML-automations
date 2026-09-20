# Status da base de migrations — honestidade de lacunas

Este diretório **não é uma sequência completa e executável do zero**. É o melhor estado
recuperável, mais as correções feitas a partir daqui. Não presuma completude.

## Presentes (recuperadas individualmente, tratadas como canônicas)
006, 007, 013, 015, 016, 017, 019, 026, 027, 029, 035, 036, 037, 038, 039, 040, 042.

## Ausentes (não inventadas — NÃO reconstruir por suposição)
001–005, 010–012, 014, 018, 020–025, 028, 030–034, 041.

Efeito prático: pelo menos os seguintes objetos são referenciados por migrations presentes neste
diretório mas **não têm `CREATE`/`ALTER` neste repositório** — presume-se que vieram de uma das
migrations ausentes acima. Ver `docs/AUDIT/PHASE_A.md` §I e
`supabase/scripts/introspection/00_readonly_contract_check.sql` para o plano de confirmação.

**Atualizado em 2026-09-20 com o resultado real da AÇÃO-001 (Seção 8 — checklist de existência).**
Recebemos até agora **somente a Seção 8** (existência via `pg_proc`/`pg_class`/`information_schema.columns`)
do script `00_readonly_contract_check.sql`. Isso confirma/refuta **existência**, não **forma exata**
(assinatura completa de função, lista de colunas, defaults, constraints). Por isso os itens abaixo
que existem ficam `CONFIRMED (existence only) — SIGNATURE STILL UNVERIFIED` até recebermos as Seções
3 (assinaturas completas) e 4 (colunas completas) do mesmo script.

| Objeto | Referenciado por | Status |
|---|---|---|
| `core.finalize_assistant_turn` | n8n (todos os workflows), 048, 054 | **CONFIRMED (existence only)** — existe em STAGING. Assinatura exata ainda não recebida (Seção 3 pendente). |
| `core.select_and_confirm_slot_offer_option_v3` | 038, 042 | **CONFIRMED (existence only)** — existe. Assinatura exata pendente. |
| `core.appointment_calendar_syncs` (tabela) | 035, 042, n8n | **CONFIRMED (existence only)** — existe. Colunas exatas pendentes (Seção 4). |
| `core.prepare_appointment_calendar_sync` | 035, 042, 051 | **CONFIRMED (existence only)** — existe. Assinatura exata pendente. |
| `core.complete_appointment_calendar_sync` | 051 | **CONFIRMED (existence only)** — existe. Assinatura exata pendente. |
| `core.fail_appointment_calendar_sync` | 051 | **CONFIRMED (existence only)** — existe. Assinatura exata pendente. |
| `core.prepare_assistant_context` | 029 | **CONFIRMED (existence only)** — existe. Assinatura exata pendente. |
| `core.run_housekeeping_v2` | n8n workflow 07 | **DISPROVED — genuinamente ausente em STAGING.** Confirma RISK-006: o workflow scheduler (n8n 07, poll 300s) vai falhar com "function does not exist" a cada execução assim que for ativado. Precisa ser criado ou o node precisa parar de chamá-lo antes de qualquer ativação. |
| `core.set_updated_at` (trigger fn) | 046, 057 | **CONFIRMED (existence only)** — existe. |
| `core.customer_preferences` (forma atual) | 052, 054, 055 | **CONFIRMED existência** — existe. Forma exata das colunas ainda pendente (Seção 4) — a reconstrução 008 permanece não confirmada como byte-idêntica. |
| `core.customer_engagement_profiles` (forma atual) | 052, 055 | **CONFIRMED existência** — existe. Forma exata das colunas ainda pendente (Seção 4). |
| `business_settings.rescheduling_enabled` | 042 | **CONFIRMED** — coluna existe. |
| `business_settings.rescheduling_notice_minutes` | 042 | **CONFIRMED** — coluna existe. |
| `UNIQUE(business_id, id)` em `core.messages` | necessário para qualquer FK composta tipo `(business_id, message_id) REFERENCES core.messages(business_id, id)` | **DISPROVED — a constraint NÃO existe.** Confirma a hipótese levantada na Fase A (D.2): a migration 051 original (com a `CREATE TABLE core.message_delivery_events(...FOREIGN KEY (business_id, message_id) REFERENCES core.messages(business_id, id)...)`) teria falhado como **DDL inválido** contra STAGING real, não só colidido em runtime. Confirma que a correção de P0.1 (evitar completamente essa forma de tabela/FK, reutilizando `core.apply_message_delivery_status`/`core.bind_outbound_external_message` de 027) foi estruturalmente necessária, não só estilisticamente melhor. |
| `core.businesses.code` | migration 048 original (bug já corrigido em P0.5) | **DISPROVED — coluna não existe.** Confirma definitivamente D.8/RISK-008: o bug era real, a correção (`business_code`) é a forma certa. |
| `core.select_and_confirm_slot_offer_option` (não-v3, de 026) | 026, fallback em 038/042 | **CONFIRMED** — existe, consistente com a migration 026 já presente neste repositório. |
| `core.leave_waitlist` (não-v2) | referenciado defensivamente em 054 dentro de um bloco `EXCEPTION WHEN undefined_function` | **DISPROVED — genuinamente ausente em STAGING.** Confirma que o tratamento defensivo em 054 (`execute_assistant_action_v5`) não é paranoia redundante — é necessário: uma chamada direta sem esse guard falharia. |

## Migrations candidatas (043–057)

Aplicadas e verificadas em STAGING até 050 inclusive (048 com a correção `business_code`).
051–057 são candidatas, **não presumir aplicadas**. 051 tem colisão de contrato confirmada
(ver `docs/AUDIT/PHASE_A.md` D.2) — corrigida nesta base em migration corretiva numerada, nunca
reescrevendo o arquivo histórico em silêncio (ver cabeçalho de `051_whatsapp_calendar_hardening.sql`
e a migration corretiva subsequente uma vez criada).

## Regra de ouro

Se este arquivo diverge de uma introspecção real e atual de STAGING, **a introspecção vence**.
Atualize este arquivo depois de cada introspecção nova.
