# LEGACY MIGRATION SOURCE MAP

## Fontes identificadas e incluídas

- 006 — appointments foundation
- 007 — messaging foundation
- 013 — appointment transaction functions
- 015 — availability engine
- 016 — integrate availability into hold
- 017 — slot generation engine
- 019 — slot offer transaction functions
- 026 — assistant slot confirmation
- 027 — assistant messaging engine
- 029 — assistant turn cleanup
- 035 — appointment cancellation foundation
- 036 — cancellation notification engine
- 037 — cancellation outbound messaging
- 038 — cancelled appointment rebooking
- 039 — exclude cancelled slot from rebooking
- 040 — fix rebooking slot prune contract
- 042 — active appointment rescheduling

## Reconstrução não canônica

- 008/009 — existe referência reconstruída a partir do schema/estado anterior. NÃO tratar como migration literal original.

## Arquivo não mapeado

- snapshot de `get_assistant_context` incluído para referência de contrato.

## Ausentes neste pacote montado

Não há garantia de arquivos individuais exatos para:

001–005, 010–012, 014, 018, 020–025, 028, 030–034, 041.

Se existirem localmente, coloque-os em:

`05_USER_ADDITIONS/exact_migrations_001_042_if_available/`

Mesmo sem todos os arquivos históricos, um `schema.sql` real de STAGING permite auditorar o contrato atual com muito mais segurança.
