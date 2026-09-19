# ML CLAUDE MASTER HANDOFF — FINAL

Este pacote reúne tudo que foi possível recuperar e organizar do projeto **ML Automações** dentro desta conversa e dos arquivos disponíveis, já preparado para entregar a um agente de engenharia.

## Ordem inicial

1. `00_START_HERE/00_MASTER_PROMPT_CLAUDE.md`
2. `00_START_HERE/01_PRODUCT_VISION_AND_DOMAIN_REQUIREMENTS.md`
3. `00_START_HERE/02_CURRENT_STATE_AND_TRUST_ORDER.md`
4. `10_DATABASE_REALITY_AND_PATCHES/`
5. `00_START_HERE/06_HANDOFF_MANIFEST.md`
6. `00_START_HERE/10_CLAUDE_FIRST_MESSAGE.txt`

## O que já está dentro

- implementação atual PROD FINAL LUNA completa;
- migrations 043–057;
- one-shot 043–057;
- preflight da base 001–042;
- workflows n8n;
- Edge Functions;
- app ML Console;
- prompts e schemas;
- testes/validadores;
- V3 canônica;
- V3 modificada problemática;
- V3.1 experimental;
- migrations históricas recuperadas individualmente;
- migration 042 canônica;
- históricos RC1/intermediário;
- snapshots reais de runtime e funções;
- variante 048 efetivamente aplicada em STAGING;
- fatos reais de schema observados durante a instalação;
- análise da incompatibilidade conhecida da 051;
- requisitos completos de produto;
- aprofundamento ML Food / KDS / impressão / PDV / WhatsApp/Instagram-first;
- identidade visual disponível;
- prompt mestre de execução;
- plano de entrega em ~1 mês;
- regras de segurança, staging, testes, observabilidade e definição de pronto.

## Privacidade

Dados pessoais/runtime que não eram necessários para engenharia foram substituídos por placeholders. Secrets reais não foram incluídos.

## Limitação documental conhecida

O dump exato `schema.sql` que existiu apenas no computador local do usuário não está disponível neste runtime. Em vez de inventá-lo, o pacote contém um **best-known database reality snapshot** e instruções para pedir uma única introspecção segura de STAGING apenas se for realmente necessária.

Não bloquear a auditoria inicial por isso.

## Regra máxima

**PROD não deve ser alterado automaticamente.** Primeiro auditoria, design, implementação, testes e STAGING.
