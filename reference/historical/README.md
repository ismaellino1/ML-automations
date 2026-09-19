# Índice histórico

Este diretório não duplica arquivos — ele indexa, por caminho relativo dentro de
`reference/handoff/` (cópia imutável do pacote de handoff original), os artefatos históricos e
não-canônicos relevantes, para que fiquem fáceis de achar sem arriscar divergência de duas cópias
do mesmo arquivo.

## Linhagem evolutiva do produto (4 gerações confirmadas)

1. **V3 canônica** — workflow n8n monolítico + migrations históricas 001–042.
   - `reference/handoff/01_CURRENT_IMPLEMENTATION/v3_reference/01_CORE_UNIVERSAL_V3_CANONICAL.json`
   - Migrations recuperadas individualmente: `reference/handoff/02_LEGACY_MIGRATION_SOURCES/identified/`
     (mesmo conteúdo já vive em `supabase/migrations/` como base canônica em evolução).
2. **RC1** — primeira decomposição em múltiplos workflows.
   - `reference/handoff/03_HISTORICAL_PACKAGES/ML_AUTOMACOES_PROD_RC1/`
3. **INTERMEDIATE** — 10 workflows n8n numerados + migrations 043–050 apenas.
   - `reference/handoff/03_HISTORICAL_PACKAGES/ML_AUTOMACOES_PROD_FINAL_INTERMEDIATE/`
4. **LUNA (baseline deste repositório)** — 10 workflows + migrations 043–057 + Edge Functions +
   `ml-console`. Nunca foi validada E2E contra providers reais.
   - `reference/handoff/01_CURRENT_IMPLEMENTATION/ML_AUTOMACOES_PROD_FINAL_LUNA/`

## Variantes não-canônicas do workflow V3 (não usar como base — apenas para consulta histórica)

- **MODIFIED** (`01_CORE_UNIVERSAL_V3_NONCANONICAL_MODIFIED.json`) — extensão de roteamento de
  calendário para reschedule, salva sob o mesmo nome do workflow canônico. Ver
  `docs/AUDIT/PHASE_A.md` §D e o relatório do subagente de comparação para o diff exato.
- **EXPERIMENTAL** (`01_CORE_UNIVERSAL_V3_1_CALENDAR_ROUTING_EXPERIMENTAL.json`) — implementação
  mais minimalista do mesmo recurso, diverge de MODIFIED em IDs de nó.
- Ambas em `reference/handoff/01_CURRENT_IMPLEMENTATION/v3_reference/`.
- **Decisão registrada em P1** (ver `docs/DECISIONS.md` quando criado): reconciliar em uma única
  linhagem canônica de roteamento de calendário para reschedule antes de qualquer workflow n8n
  deste tipo ser reativado.

## Reconstruções explicitamente não-canônicas

- `reference/handoff/02_LEGACY_MIGRATION_SOURCES/reconstructed_reference/008_customer_memory_and_profiles`
  e `009_business_configuration` — reconstruídos a partir do schema *atual*, não são o texto
  original das migrations 008/009. **Não foram copiados para `supabase/migrations/`** para evitar
  que uma reconstrução passe por migration real. Servem apenas como evidência de forma provável.
- `reference/handoff/02_LEGACY_MIGRATION_SOURCES/unmapped_reference/` — contrato de
  `core.get_assistant_context`, não vinculado a um número de migration específico, mas
  confirmado como carregado (ver auditoria).

## Pacotes históricos completos (para diff/comparação apenas)

- `reference/handoff/03_HISTORICAL_PACKAGES/ML_AUTOMACOES_PROD_RC1/`
- `reference/handoff/03_HISTORICAL_PACKAGES/ML_AUTOMACOES_PROD_FINAL_INTERMEDIATE/`

## Snapshots de runtime e extrações brutas (evidência, não contrato)

- `reference/handoff/04_RUNTIME_SNAPSHOTS/`
- `reference/handoff/09_RAW_SOURCE_EXTRACTS/`
