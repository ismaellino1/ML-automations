# Known Limitations

Mantido continuamente. Nada aqui é escondido.

## Herdadas da auditoria Fase A (baixa severidade, D.17–D.21)

- D.17 — Uma correção da 051 precisa reintroduzir proteção de idempotência equivalente ao
  `event_key UNIQUE` do contrato real da 027; não reinventar sem essa proteção.
- D.18 — `core.check_slot_availability`'s `p_ignore_appointment_id` nunca é passado por nenhum
  caller, incluindo o motor de reschedule (042) — impede reoferecer o horário atual do cliente
  como opção durante remarcação. Não é bug, é uma limitação de UX conhecida.
- D.19 — Nós órfãos no workflow n8n canônico original (`12 - ENVIAR WHATSAPP META` nativo,
  `12 - DEV SIMULAR ENVIO META`) — resquício de desenvolvimento, não impacta produção.
- D.20 — Mismatch cosmético entre nome de arquivo e cabeçalho em `046_automation_reminders.sql`.
- D.21 — `core.customer_marketing_preferences` (045) fica órfã após 052 redefinir
  `set_marketing_consent_v1` para escrever em `core.customer_preferences`. Sob aplicação
  estritamente ordenada não é bug, mas é uma tabela morta sem migration de remoção.

## Estruturais (aguardando decisão ou introspecção)

- Migrations 001-005, 010-012, 014, 018, 020-025, 028, 030-034, 041 não estão disponíveis neste
  pacote. Seus efeitos são inferidos onde possível (ver `supabase/migrations/MIGRATION_BASE_STATUS.md`),
  nunca reconstruídos por suposição.
- ML Food/Commerce/Payments/Inventory não foram iniciados neste código — 100% greenfield (P2+).
- Nenhuma parte do sistema foi validada E2E contra Meta/Google Calendar/OpenAI/Supabase reais.
