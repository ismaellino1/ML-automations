# Implementação — ordem final

Este pacote assume que o banco atual já contém a base verificada até a migration 042.

## Banco
1. Faça backup/PITR do projeto atual.
2. Rode `supabase/preflight/BASE_001_042_CONTRACT.sql`.
3. Em STAGING, aplique `supabase/migrations/043...057` em ordem.
   - Alternativa operacional: `supabase/one_shot/043_057_ML_PROD_FINAL_AFTER_042.sql`.
4. Rode os testes SQL.
5. Só então repita em PROD.

## Edge Functions
Implante:
- `media-processor`
- `control-api`

Cadastre os secrets de `.env.example`. Nunca coloque service role, Meta token ou OpenAI key no frontend.

## n8n
Importe, ainda inativos:
1. `01_ML_INBOUND_GATEWAY_PROD_FINAL.json`
2. `02_ML_MEDIA_WORKER_PROD_FINAL.json`
3. `03_ML_CONVERSATION_WORKER_PROD_FINAL.json`
4. `04_ML_WHATSAPP_DELIVERY_PROD_FINAL.json`
5. `05_ML_GOOGLE_CALENDAR_PROD_FINAL.json`
6. `06_ML_CAMPAIGN_ENGINE_PROD_FINAL.json`
7. `07_ML_AUTOMATION_SCHEDULER_PROD_FINAL.json`
8. `08_ML_CONTROL_PLANE_PROD_FINAL.json`
9. `09_ML_KNOWLEDGE_INGESTION_PROD_FINAL.json`
10. `99_ML_OBSERVABILITY_PROD_FINAL.json`

Reassocie apenas as credenciais existentes: PostgreSQL, WhatsApp/Meta, Google Calendar, OpenAI e Header Auth interno.

## Ativação
Ative primeiro workers/observability e por último o Inbound Gateway.
Não desligue o V3 até a matriz E2E passar no novo conjunto.

## Critério de corte
O novo runtime só substitui o V3 depois de:
- booking;
- select slot;
- cancel;
- rebooking;
- active rescheduling;
- Calendar CREATE/DELETE;
- áudio/imagem/documento;
- delivery receipts;
- waitlist;
- reminders;
- campaigns/opt-out;
- RBAC;
- retry/dead-letter;
- tenant isolation;
- duplicate webhook;
- provider outage/recovery.

Sem essas validações o pacote é implementação final, mas ainda não uma release operacional aprovada.
