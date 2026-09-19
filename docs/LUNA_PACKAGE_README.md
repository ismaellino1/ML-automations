# ML AUTOMAÇÕES — PROD FINAL LUNA

Pacote de implementação final sobre a base já validada até a migration 042.

## Arquitetura
PostgreSQL/Supabase é a fonte de verdade. O n8n interpreta e orquestra; regras empresariais,
idempotência, estado, concorrência e side effects duráveis permanecem no Core.

### Runtime
Meta → Inbound Gateway → Core
- texto/interação → Conversation Worker
- mídia → Media Worker → Conversation Worker
- resposta → WhatsApp Outbox Worker
- Calendar → Calendar Worker
- falha externa → retry/backoff/dead-letter

### Plataforma
- ML Admin
- ML Manager
- ML Employee

As três superfícies usam o mesmo Core multi-tenant e RBAC.

## IA padrão
`gpt-5.6-luna` no Orchestrator, Response Engine e análise multimodal. Áudio usa
`gpt-4o-mini-transcribe` antes da interpretação.

## Banco
- Base existente: 001–042.
- Overlay final: 043–057.
- Preflight: `supabase/preflight/BASE_001_042_CONTRACT.sql`.
- One-shot após 042: `supabase/one_shot/043_057_ML_PROD_FINAL_AFTER_042.sql`.

## Começar
Leia `IMPLEMENTATION_ORDER.md`.

## Garantia técnica
Os arquivos passam validação estática de estrutura, referências de workflow, expressões e política
de modelo. A aprovação de produção exige E2E na sua própria instância do Supabase, n8n, Meta,
Google Calendar e OpenAI; isso não pode ser simulado com fidelidade apenas pelo arquivo.
