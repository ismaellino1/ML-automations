# Exact schema dump status

O `schema.sql` gerado no computador local durante o backup de PROD não está disponível dentro dos arquivos desta conversa/runtime, portanto não foi possível incluí-lo byte a byte neste handoff sem pedir novo upload ao usuário.

Para evitar fingir que um schema reconstruído é o schema real, este pacote inclui em seu lugar:

- `BASE_001_042_CONTRACT.sql`;
- migrations históricas recuperadas;
- migration 042 canônica;
- overlay 043–057;
- variante 048 efetivamente aplicada no STAGING registrado;
- snapshots de funções/runtime;
- fatos de schema consultados diretamente no STAGING;
- análise detalhada da colisão 051.

Se durante a implementação for necessária introspecção completa, gere UM script/comando de introspecção seguro e peça ao usuário apenas para executá-lo localmente contra STAGING. Não bloquear a auditoria inicial por causa disso e não inventar objetos ausentes.
