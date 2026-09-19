# KNOWN ISSUES TO REVERIFY — NÃO ASSUMIR COMO ÚNICOS

Estes pontos foram identificados durante instalação em STAGING. Claude deve confirmá-los independentemente e procurar outros.

## 1. Migration 048 — coluna de businesses

A versão original usava `SELECT code FROM core.businesses`; a base real conhecida usa `business_code`. Uma cópia corrigida foi aplicada em STAGING.

## 2. Migration 051 — collision em `core.message_delivery_events`

A base histórica já possui `core.message_delivery_events` com contrato legado contendo, entre outros, `raw_payload`, `event_key`, `applied_message_id`, `applied_at`.

A 051 candidata foi escrita como se pudesse criar outra estrutura com `message_id` e `payload`.

`CREATE TABLE IF NOT EXISTS` não migra a estrutura existente; portanto a função posterior pode compilar e falhar em runtime.

Não aplicar 051 original sem reconciliar o contrato real.

## 3. Job attempt worker_ref

Revisar se `complete_integration_job_v1` limpa `lease_owner` antes de gravar attempt, perdendo `worker_ref`.

## 4. Webhook exception persistence

Revisar a semântica transacional de `ingest_whatsapp_webhook_final` ao registrar erro e depois `RAISE`.

## 5. Tenant scoping de delivery receipt

Revisar lookup por provider + external_message_id sem tenant/channel explícito.

## 6. 045 campaign functions

Executar testes de runtime; criação de função não é garantia de ausência de ambiguidades ou dependências tardias.

## 7. Static PASS != E2E

Meta templates, Calendar, OpenAI, Edge Functions, RLS/JWT e provider recovery ainda precisam de validação real.
