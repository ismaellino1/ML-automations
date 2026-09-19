# ML AUTOMAÇÕES — PROD FINAL

Arquitetura de produção multi-tenant para atendimento, agenda, automações, campanhas e operação.

## Componentes
- Inbound Gateway: recebe WhatsApp e registra tudo de forma idempotente.
- Media Worker: áudio, imagem, documento, vídeo e sticker; usa um processador isolado.
- Conversation Worker: IA orquestradora + Core + Response Engine.
- WhatsApp Delivery: outbox, retry, WAMID e dead-letter.
- Google Calendar: jobs assíncronos, reconciliação e idempotência.
- Campaign Engine: campanhas, consentimento e supressão.
- Automation Scheduler: reminders, waitlist, reactivation e housekeeping.
- Control Plane: ML Admin / Manager / Employee.
- Knowledge Ingestion: base factual da empresa.
- Observability: incidentes e trilha operacional.
- ML Console: SPA única com superfícies por RBAC.

## Princípio central
PostgreSQL é a fonte de verdade. n8n nunca decide regra empresarial; apenas interpreta e orquestra.
Side effects externos usam fila/lease/retry. Nenhuma resposta, Calendar ou campanha depende de uma
cadeia frágil dentro do turno conversacional.

## Importação
1. aplique migrations 043–050 sobre o banco que já possui 001–042;
2. configure Edge Functions `media-processor` e `control-api`;
3. configure segredos/credenciais;
4. importe workflows na ordem 01,02,03,04,05,06,07,08,09,99;
5. mantenha tudo INATIVO até passar os testes E2E;
6. ative workers; depois gateway.

## Variáveis
Veja `.env.example`.

## Limite objetivo
O código foi desenhado para produção, mas nenhuma integração externa pode ser declarada
validada sem E2E na sua instância real de n8n, Supabase, Meta e Google.
