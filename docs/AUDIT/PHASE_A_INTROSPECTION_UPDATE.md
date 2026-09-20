# Fase A — atualização pós-introspecção (AÇÃO-001)

Data: 2026-09-20
Fonte: saída da Seção 8 (`00_readonly_contract_check.sql`) rodada pelo usuário contra STAGING real.

**Status**: recebemos até agora **somente a Seção 8** (checklist de existência — 18 itens). As
Seções 0–7 (ambiente, inventário completo de tabelas, **assinaturas completas de função**,
**definições completas de coluna**, constraints, triggers, controle de migrations) ainda não
foram recebidas e continuam pendentes — ver `MANUAL_ACTIONS_FOR_ISMAEL.md` AÇÃO-001 (reaberta).

## O que a Seção 8 confirma (existência apenas, não forma exata)

| # | Item | Resultado real | Efeito |
|---|---|---|---|
| 1 | `core.finalize_assistant_turn` | **EXISTE** | D.3/RISK-003 rebaixado — função load-bearing confirmada real. Assinatura exata ainda não confirmada. |
| 2 | `core.select_and_confirm_slot_offer_option_v3` | **EXISTE** | D.9/RISK-009 rebaixado. |
| 3 | `core.appointment_calendar_syncs` (tabela) | **EXISTE** | D.10/RISK-010 rebaixado. |
| 4 | `core.prepare_appointment_calendar_sync` | **EXISTE** | D.10/RISK-010 rebaixado. |
| 5 | `core.complete_appointment_calendar_sync` | **EXISTE** | D.10/RISK-010 rebaixado. |
| 6 | `core.fail_appointment_calendar_sync` | **EXISTE** | D.10/RISK-010 rebaixado. |
| 7 | `core.prepare_assistant_context` | **EXISTE** | Load-bearing para `prepare_assistant_turn` (029) confirmada real. |
| 8 | `core.run_housekeeping_v2` | **NÃO EXISTE** | **RISK-006 confirmado real, não mais hipótese.** O node "11 - HOUSEKEEPING" do workflow n8n 07 vai falhar a cada execução (poll 300s) assim que o workflow for ativado. Precisa de decisão em P1: criar a função, ou remover/desabilitar o node. |
| 9 | `core.set_updated_at` | **EXISTE** | Confirma a suposição segura usada no harness local de testes (a implementação sintética usada lá é apenas para testes, nunca foi aplicada a STAGING). |
| 10 | `core.customer_preferences` (tabela) | **EXISTE** | Forma exata das colunas ainda não confirmada (Seção 4 pendente). |
| 11 | `core.customer_engagement_profiles` (tabela) | **EXISTE** | Forma exata das colunas ainda não confirmada. |
| 12 | `business_settings.rescheduling_enabled` | **EXISTE** | Confirma a dependência não-declarada da migration 042. |
| 13 | `business_settings.rescheduling_notice_minutes` | **EXISTE** | Idem. |
| 14 | `UNIQUE(business_id, id)` em `core.messages` | **NÃO EXISTE** | **Confirma a hipótese mais importante da auditoria de P0.1**: a migration 051 original, com sua `FOREIGN KEY (business_id, message_id) REFERENCES core.messages(business_id, id)`, teria sido **DDL inválido** contra STAGING real (Postgres exige `UNIQUE`/`PK` nas colunas referenciadas de uma FK composta) — não apenas uma colisão de runtime, como já documentado. A correção de P0.1 evitou completamente essa forma de tabela, o que agora está confirmado como tendo sido a decisão estruturalmente correta, não apenas estilística. |
| 15 | `core.businesses.business_code` | **EXISTE** | Confirma o alvo da correção de P0.5. |
| 16 | `core.businesses.code` | **NÃO EXISTE** | **Confirma definitivamente D.8/RISK-008** — o bug original (`SELECT code FROM core.businesses`) era real; `business_code` é o nome certo. |
| 17 | `core.select_and_confirm_slot_offer_option` (não-v3) | **EXISTE** | Consistente com a migration 026 já presente neste repositório. |
| 18 | `core.leave_waitlist` (não-v2) | **NÃO EXISTE** | Confirma que o tratamento defensivo em 054 (`EXCEPTION WHEN undefined_function`) é necessário e correto como está — não é código morto. |

## Resumo

**14 de 18 itens CONFIRMADOS EXISTENTES**, 3 **CONFIRMADOS AUSENTES de fato** (`run_housekeeping_v2`,
`UNIQUE(business_id,id)` em `messages`, `leave_waitlist` não-v2), 1 confirmado ausente como esperado
(`businesses.code`, o bug já corrigido).

**Nenhum falso positivo da auditoria original foi encontrado até agora** — toda hipótese levantada em
`docs/AUDIT/PHASE_A.md` que já pôde ser checada bateu com a realidade de STAGING.

## O que ainda falta para fechar P0.6 por completo

Existência confirmada não é o mesmo que contrato confirmado. Antes de qualquer trabalho no motor de
Appointments (reschedule/rebook/slot-offer) em P1, ainda precisamos, via as Seções 3 e 4 do mesmo
script (pendentes):

- Assinatura exata (ordem/tipo de cada parâmetro, valor de retorno) de `finalize_assistant_turn`,
  `select_and_confirm_slot_offer_option_v3`, `prepare_appointment_calendar_sync`,
  `complete_appointment_calendar_sync`, `fail_appointment_calendar_sync`, `prepare_assistant_context`
  — para confirmar que os call sites existentes (038, 042, 048, 054, n8n) realmente chamam essas
  funções com os argumentos certos, na ordem certa. Existência não garante isso — o próprio ciclo P0
  encontrou múltiplos bugs de assinatura (D.5, RISK-017) em funções que **também existiam**.
- Colunas exatas de `core.appointment_calendar_syncs`, `core.customer_preferences`,
  `core.customer_engagement_profiles`.

Ver `MANUAL_ACTIONS_FOR_ISMAEL.md` — AÇÃO-001 permanece aberta, agora pedindo especificamente a
saída completa (todas as 9 seções), não apenas a Seção 8.
