# Domain: ML Appointments

Status: **mais maduro do pacote**. Motor de disponibilidade/hold/confirm/cancel/rebook/reschedule
(migrations 006-042) transacionalmente cuidadoso — locking ordenado, guards de status,
rollback atômico com idioma de exceção P0001 reusado consistentemente.

Contratos SQL: `supabase/migrations/006,007,013,015,016,017,019,026,027,029,035-040,042*.sql`.
Gaps de fiação (não de design) documentados em `docs/AUDIT/PHASE_A.md` D.3, D.9, D.10.

Este diretório recebe documentação de domínio (contratos, decisões, invariantes de negócio)
conforme a Fase B avança. Não duplica as migrations, que continuam em `supabase/migrations/`.
