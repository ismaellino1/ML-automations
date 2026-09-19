# Arquitetura

Fluxo principal:

Meta → Inbound Gateway → Core
- texto/interação → CONVERSATION_TURN
- mídia → MEDIA_PROCESS → CONVERSATION_TURN

Conversation Worker → execute_assistant_action_v5 → Core
- Calendar vira CALENDAR_SYNC job
- resposta vira WHATSAPP_OUTBOUND job

Workers são independentes, com lease, retry e dead-letter.

ML Admin, Manager e Employee compartilham um único ML Console e o mesmo Core.
As diferenças são RBAC e escopo de dados, não cópias de aplicação.
