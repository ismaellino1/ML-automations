# Status da base de migrations — honestidade de lacunas

Este diretório **não é uma sequência completa e executável do zero**. É o melhor estado
recuperável, mais as correções feitas a partir daqui. Não presuma completude.

## Presentes (recuperadas individualmente, tratadas como canônicas)
006, 007, 013, 015, 016, 017, 019, 026, 027, 029, 035, 036, 037, 038, 039, 040, 042.

## Ausentes (não inventadas — NÃO reconstruir por suposição)
001–005, 010–012, 014, 018, 020–025, 028, 030–034, 041.

Efeito prático: pelo menos os seguintes objetos são referenciados por migrations presentes neste
diretório mas **não têm `CREATE`/`ALTER` neste repositório** — presume-se que vieram de uma das
migrations ausentes acima. Ver `docs/AUDIT/PHASE_A.md` §I e
`supabase/scripts/introspection/00_readonly_contract_check.sql` para o plano de confirmação.

| Objeto | Referenciado por | Status |
|---|---|---|
| `core.finalize_assistant_turn` | n8n (todos os workflows), 048, 054 | UNVERIFIED |
| `core.select_and_confirm_slot_offer_option_v3` | 038, 042 | UNVERIFIED |
| `core.appointment_calendar_syncs` (tabela) | 035, 042, n8n | UNVERIFIED |
| `core.prepare_appointment_calendar_sync` | 035, 042, 051 | UNVERIFIED |
| `core.complete_appointment_calendar_sync` | 051 | UNVERIFIED |
| `core.fail_appointment_calendar_sync` | 051 | UNVERIFIED |
| `core.prepare_assistant_context` | 029 | UNVERIFIED |
| `core.run_housekeeping_v2` | n8n workflow 07 | UNVERIFIED |
| `core.set_updated_at` (trigger fn) | 046, 057 | UNVERIFIED |
| `core.customer_preferences` (forma atual) | 052, 054, 055 | PARTIALLY EVIDENCED (reconstrução 008, não original) |
| `core.customer_engagement_profiles` (forma atual) | 052, 055 | PARTIALLY EVIDENCED (reconstrução 008, não original) |
| `business_settings.rescheduling_enabled` | 042 | PARTIALLY EVIDENCED (reconstrução 009, não original) |
| `business_settings.rescheduling_notice_minutes` | 042 | PARTIALLY EVIDENCED (reconstrução 009, não original) |
| `UNIQUE(business_id, id)` em `core.messages` | necessário para qualquer FK composta tipo `(business_id, message_id) REFERENCES core.messages(business_id, id)` | UNVERIFIED |

## Migrations candidatas (043–057)

Aplicadas e verificadas em STAGING até 050 inclusive (048 com a correção `business_code`).
051–057 são candidatas, **não presumir aplicadas**. 051 tem colisão de contrato confirmada
(ver `docs/AUDIT/PHASE_A.md` D.2) — corrigida nesta base em migration corretiva numerada, nunca
reescrevendo o arquivo histórico em silêncio (ver cabeçalho de `051_whatsapp_calendar_hardening.sql`
e a migration corretiva subsequente uma vez criada).

## Regra de ouro

Se este arquivo diverge de uma introspecção real e atual de STAGING, **a introspecção vence**.
Atualize este arquivo depois de cada introspecção nova.
