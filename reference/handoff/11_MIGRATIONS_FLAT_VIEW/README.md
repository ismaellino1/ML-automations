# MIGRATIONS — FLAT VIEW

Atalho para revisão rápida.

- migrations históricas recuperadas individualmente: 006, 007, 013, 015, 016, 017, 019, 026, 027, 029, 035–040, 042;
- migrations overlay atuais: 043–057;
- `048_runtime_v5_adapters.APPLIED_STAGING.sql`: variante efetivamente aplicada no STAGING registrado;
- `BASE_001_042_CONTRACT.sql`: preflight da base;
- `043_057_ML_PROD_FINAL_AFTER_042.sql`: one-shot do pacote, apenas referência; não pressupor aplicação.

As migrations históricas ausentes individualmente não devem ser inventadas. Use contratos, snapshots e, quando houver acesso ao banco, introspecção real.
