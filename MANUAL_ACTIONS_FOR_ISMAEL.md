# Manual Actions for Ismael

Ações que só você pode fazer — dependem de credenciais, painel, conta ou decisão externa.
Nunca peço secret/token/senha no chat.

---

## AÇÃO-001 — Rodar introspecção read-only de STAGING

- **Objetivo**: resolver os itens `UNVERIFIED` da auditoria (funções/tabelas ausentes deste
  pacote: `finalize_assistant_turn`, `select_and_confirm_slot_offer_option_v3`,
  `appointment_calendar_syncs` e funções de ciclo de vida, `prepare_assistant_context`,
  `run_housekeeping_v2`, `set_updated_at`, forma real de `customer_preferences` e
  `customer_engagement_profiles`, origem de `business_settings.rescheduling_*`, e se
  `core.messages` tem `UNIQUE(business_id,id)`).
- **Ambiente**: STAGING (nunca PROD).
- **Pré-requisitos**: acesso ao SQL editor do projeto Supabase STAGING, ou uma
  `STAGING_DATABASE_URL` para `psql`.
- **Comando/caminho exato**: `supabase/scripts/introspection/00_readonly_contract_check.sql` —
  instruções completas em `supabase/scripts/introspection/README.md`.
- **O que você precisa preencher**: nada no script (é 100% genérico); só executar e copiar a
  saída completa das 9 seções.
- **Resultado esperado**: uma tabela "Seção 8" com 18 linhas `found = true/false` mais 7 seções
  de evidência de suporte.
- **Como validar**: a Seção 8 deve ter pelo menos as linhas 15/16 respondendo claramente se
  `business_code` existe e se `code` existe em `core.businesses` (confirma/refuta D.8).
- **Como desfazer se falhar**: não aplicável — é somente leitura, não há o que desfazer.
- **Risco**: nenhum (somente leitura).
- **Status**: **PARCIALMENTE ATENDIDA (2026-09-20)** — recebi a Seção 8 (checklist de existência,
  18/18 itens respondidos). Resultado processado e registrado em
  `docs/AUDIT/PHASE_A_INTROSPECTION_UPDATE.md` e no `RISK_REGISTER.md`. **Ainda faltam as Seções
  0–7** (ambiente, inventário completo de tabelas, **assinaturas completas de função** — Seção 3,
  **colunas completas** — Seção 4, constraints, triggers, controle de migrations). Existência
  confirmada não é o mesmo que contrato confirmado: preciso da Seção 3 (assinaturas exatas de
  `finalize_assistant_turn`, `select_and_confirm_slot_offer_option_v3`,
  `prepare/complete/fail_appointment_calendar_sync`, `prepare_assistant_context`) e da Seção 4
  (colunas de `appointment_calendar_syncs`, `customer_preferences`, `customer_engagement_profiles`)
  antes de fechar P0.6 por completo e antes de considerar seguro trabalhar no motor de
  Appointments em P1. **Reabra a saída completa do mesmo script** (rode de novo se precisar —
  ainda é 100% somente leitura) e devolva o resultado inteiro, não só a Seção 8.

---

*(Demais ações manuais — credenciais de provider para Meta/Google Calendar/OpenAI, aplicação em
STAGING das migrations corretivas P0, aprovação para qualquer coisa em PROD — serão adicionadas
aqui conforme cada P0 for concluído e exigir uma ação externa específica.)*
