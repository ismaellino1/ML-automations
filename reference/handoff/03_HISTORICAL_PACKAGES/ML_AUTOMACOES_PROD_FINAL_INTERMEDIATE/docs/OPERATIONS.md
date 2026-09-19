# Operação
- workers stateless;
- jobs RUNNING possuem lease e retornam a RETRY quando lease expira;
- retries 5s, 15s, 60s, 5m, 15m, 1h; depois dead-letter;
- métricas mínimas: queue depth, oldest pending, dead count, provider latency, error rate;
- backups do Postgres + PITR;
- staging separado de production;
- migrations versionadas e nunca editadas após release;
- rollback é migration corretiva, não apagar histórico.
