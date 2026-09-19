# Platform — camada compartilhada

Documentação da camada comum (Identity/Tenancy, Communication, AI Runtime, Knowledge,
Jobs/Outbox, Security, Observability, Integrations), conforme mapeado em
`docs/AUDIT/PHASE_A.md` seção F. Implementação vive em `supabase/migrations/` (funções/tabelas
`core.*` de propósito geral) e `supabase/functions/` (Edge Functions).

Estado por subcamada:
- **Identity/Tenancy/RBAC**: existe, com duas gerações paralelas (`_v1`/`_v2`) — consolidação em
  P0.7.
- **Communication**: sólida (migrations 007, 027) — contrato mais bem construído do pacote.
- **AI Runtime**: padrão de dois-LLM (Orchestrator + Response Engine) com fronteira de verdade
  real — ver `prompts/` e `schemas/`. Política de modelo desconectada (RISK-011).
- **Jobs/Outbox**: sólida, com um bug pontual de observabilidade (RISK-007).
- **Observability**: existe, quebrada no ponto de entrada global (RISK-005) — correção P0.3.
