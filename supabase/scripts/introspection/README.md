# Introspecção read-only de STAGING

`00_readonly_contract_check.sql` resolve todos os itens `UNVERIFIED` da auditoria Fase A
(`docs/AUDIT/PHASE_A.md` §I) contra o banco real, em vez de reconstruir por suposição.

**100% somente leitura** — apenas `SELECT` contra `information_schema`/`pg_catalog`. Nenhum
`CREATE`/`ALTER`/`DROP`/`INSERT`/`UPDATE`/`DELETE`, nenhuma chamada de função. Não exige
superusuário.

## Como rodar

- **Opção A (Supabase SQL editor)**: cole o conteúdo do arquivo inteiro no SQL editor do
  projeto STAGING e execute. Copie a saída completa de todas as seções (0-8).
- **Opção B (psql)**:
  ```
  psql "$STAGING_DATABASE_URL" -f 00_readonly_contract_check.sql -o result.txt
  ```

## O que fazer com o resultado

Leia primeiro a **Seção 8** (checklist final) — responde diretamente aos 12+ itens pendentes.
As seções 0-7 são evidência de suporte, necessárias para casos em que a Seção 8 não cobre algo
que não tínhamos pensado em perguntar explicitamente (por isso a Seção 3 é um dump completo de
toda assinatura de função nos schemas `core`/`private`/`public`, não só das que já suspeitávamos).

Depois de rodar, devolva a saída completa (não só a Seção 8) para que:
1. `docs/AUDIT/PHASE_A.md` seja atualizado — cada hipótese vira `CONFIRMED`, `DISPROVED` ou
   permanece `STILL UNVERIFIED`;
2. `supabase/migrations/MIGRATION_BASE_STATUS.md` seja atualizado com fatos reais;
3. P0.6 (recuperação/documentação de contratos ausentes) seja desbloqueado.

Este passo está listado em `MANUAL_ACTIONS_FOR_ISMAEL.md` como ação pendente — esta sessão não
tem credenciais de banco de STAGING e não pode executá-lo sozinha.
