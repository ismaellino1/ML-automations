# Package inventory — ML Claude Master Handoff

This inventory is generated from the final handoff contents.

## Major areas

- `00_START_HERE/` — master prompt, product vision, current state, deliverables, one-month target, known issues, safety, first message, redaction log.
- `01_CURRENT_IMPLEMENTATION/` — current PROD FINAL LUNA package and V3 references.
- `02_LEGACY_MIGRATION_SOURCES/` — historical migrations recovered individually plus reconstructed/unmapped references.
- `03_HISTORICAL_PACKAGES/` — RC1 and intermediate packages for provenance/comparison.
- `04_RUNTIME_SNAPSHOTS/` — runtime/function/state snapshots used during previous validation.
- `05_USER_ADDITIONS/` — optional future additions only; not required to start.
- `06_HELPERS/` — helper scripts.
- `07_BRAND_ASSETS/` — ML Automações visual identity references.
- `08_ORIGINAL_ARCHIVES/` — provenance hashes of source archives; raw nested ZIP duplication intentionally omitted.
- `09_RAW_SOURCE_EXTRACTS/` — raw text/code extracts that helped reconstruct historical state, with unnecessary PII redacted.
- `10_DATABASE_REALITY_AND_PATCHES/` — observed DB facts, applied 048 variant, 051 collision analysis, staging state, risks.
- `11_MIGRATIONS_FLAT_VIEW/` — convenience flat view of recovered legacy migrations + 043–057 + preflight/one-shot.

## Important canonical/near-canonical references

- Current package: `01_CURRENT_IMPLEMENTATION/ML_AUTOMACOES_PROD_FINAL_LUNA/`
- Canonical original V3: `01_CURRENT_IMPLEMENTATION/v3_reference/01_CORE_UNIVERSAL_V3_CANONICAL.json`
- Canonical migration 042: `02_LEGACY_MIGRATION_SOURCES/identified/042_active_appointment_rescheduling.sql`
- STAGING-applied 048 variant: `10_DATABASE_REALITY_AND_PATCHES/048_runtime_v5_adapters.APPLIED_STAGING.sql`
- 051 incompatibility analysis: `10_DATABASE_REALITY_AND_PATCHES/02_051_COLLISION_ANALYSIS.md`

## Legacy migrations recovered individually

006, 007, 013, 015, 016, 017, 019, 026, 027, 029, 035, 036, 037, 038, 039, 040, 042.

008/009 are present only as explicitly marked reconstructed reference, not canonical byte-identical migration files.

The remaining 001–042 historical migrations were not available as individual source files in the accessible conversation/library. Do not invent them.

## Current overlay

043–057 are present in full from the PROD FINAL LUNA package.

Known recorded STAGING state: 043–050 applied, with 048 applied using the corrected variant; 051–057 must not be assumed applied.

## Security/privacy

No real passwords/tokens/service-role secrets are intentionally included. A few personal/runtime identifiers in snapshots/workflow examples were replaced by placeholders; see `11_REDACTION_LOG.md`.
