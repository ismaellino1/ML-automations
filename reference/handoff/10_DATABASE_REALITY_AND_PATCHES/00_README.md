# DATABASE REALITY & PATCHES

Esta pasta reúne fatos observados no STAGING e variantes realmente usadas durante a instalação.

Ordem de confiança:
1. um futuro dump/introspecção real do banco, se disponível;
2. os fatos documentados aqui que foram lidos diretamente do STAGING durante a instalação;
3. migrations históricas canônicas;
4. propostas/candidatos não aplicados.

IMPORTANTE:
- `048_runtime_v5_adapters.APPLIED_STAGING.sql` representa a variante aplicada em STAGING (correção `businesses.code` -> `businesses.business_code`).
- a migration 051 original NÃO deve ser tratada como compatível com a base 001–042 sem correção.
- nenhum arquivo desta pasta autoriza alteração em PROD.
