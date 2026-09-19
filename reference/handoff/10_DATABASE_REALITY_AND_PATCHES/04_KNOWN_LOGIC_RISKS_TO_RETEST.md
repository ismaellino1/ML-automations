# Known logic risks — reverify, do not blindly accept

Estes pontos foram identificados durante revisão manual. Eles são pistas para auditoria, não substituem análise independente.

## 043 `complete_integration_job_v1`

Possível problema de observabilidade: a função pode zerar `lease_owner` antes de usar o valor retornado para gravar `worker_ref` no histórico de attempts, resultando em `worker_ref NULL`.

## 044 catalog context

Revisar se o `LIMIT` em `get_catalog_context_v1` limita de fato o conjunto agregado de entrada ou apenas a linha agregada final.

## 045 campaign delivery

Reexecutar runtime tests das funções, especialmente possíveis ambiguidades entre variável PL/pgSQL e alias de tabela.

## 048 media insertion

Revisar contrato real de `core.media_assets` e default/uso de `provider` em caminhos criados pela 048.

## 051 delivery receipt

Além da colisão estrutural, revisar monotonicidade de status, idempotência, receipt antes do bind e tenant scoping.

## 056 webhook exception semantics

Revisar o bloco de exceção de `ingest_whatsapp_webhook_final`: gravar estado de erro e em seguida `RAISE` pode reverter a gravação devido à semântica transacional/subtransaction do PL/pgSQL.

## Tenant isolation

Revisar qualquer lookup de mensagem por `provider + external_message_id` sem `business_id` explícito. Não depender implicitamente de unicidade global do provider sem contrato formal.
