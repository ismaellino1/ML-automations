# EXPECTED DELIVERABLES & DEFINITION OF DONE

## Entregáveis de auditoria

- `AUDIT_CURRENT_STATE.md`
- `CANONICAL_SOURCE_MAP.md`
- `ARCHITECTURE_CURRENT.md`
- `ARCHITECTURE_TARGET.md`
- `DOMAIN_BOUNDARIES.md`
- `RISK_REGISTER.md`
- `MIGRATION_COMPATIBILITY_REPORT.md`
- `ROADMAP_P0_P4.md`

## Entregáveis de engenharia

Conforme o roadmap aprovado:

- código implementado;
- migrations novas/corretivas;
- testes SQL;
- testes unitários;
- testes de integração;
- E2E harness;
- n8n workflows revisados ou substituição justificada;
- Edge Functions/backend;
- frontend/apps;
- print/local agent se incluído;
- schemas/API contracts;
- seeds de STAGING;
- health checks;
- scripts de deploy/validate;
- `.env.example` atualizado;
- docs operacionais.

## Arquivos obrigatórios para o proprietário

### `MANUAL_ACTIONS_FOR_ISMAEL.md`

Somente ações manuais reais, em ordem, cada uma com:

- objetivo;
- comando/UI;
- valor esperado;
- screenshot/output esperado quando útil;
- validação;
- rollback;
- risco.

### `RELEASE_READINESS.md`

Tabela por feature:

- implemented;
- statically validated;
- integration tested;
- E2E tested;
- failure tested;
- production ready;
- blockers.

### `KNOWN_LIMITATIONS.md`

Nada deve ser ocultado.

### `CUTOVER_AND_ROLLBACK.md`

Como promover e como voltar.

## Definition of Done — feature crítica

Uma feature crítica só é “done” quando:

1. contrato está definido;
2. implementação existe;
3. autorização/tenant isolation revisados;
4. happy path testado;
5. erro/retry testados;
6. idempotência/concurrency avaliadas;
7. observabilidade existe;
8. documentação existe;
9. integração real testada quando depende de provider.

## Definition of Done — produção

“Production ready” só pode ser usado depois de E2E real em STAGING e critérios de corte aprovados.
