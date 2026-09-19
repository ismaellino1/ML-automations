# HANDOFF MANIFEST — reading and work order

## Phase 0 — understand the brief

Read in order:

1. `README_FIRST.md`
2. `00_START_HERE/00_MASTER_PROMPT_CLAUDE.md`
3. `00_START_HERE/01_PRODUCT_VISION_AND_DOMAIN_REQUIREMENTS.md`
4. `00_START_HERE/02_CURRENT_STATE_AND_TRUST_ORDER.md`
5. `00_START_HERE/03_EXPECTED_DELIVERABLES_AND_DEFINITION_OF_DONE.md`
6. `00_START_HERE/04_ONE_MONTH_EXECUTION_TARGET.md`
7. `00_START_HERE/05_KNOWN_ISSUES_TO_REVERIFY.md`
8. `00_START_HERE/08_SECURITY_AND_SECRETS_RULES.md`
9. `10_DATABASE_REALITY_AND_PATCHES/`
10. `02_LEGACY_MIGRATION_SOURCES/MIGRATION_SOURCE_MAP.md`

## Phase 1 — inspect current implementation

Read/inspect:

- `01_CURRENT_IMPLEMENTATION/ML_AUTOMACOES_PROD_FINAL_LUNA/`
- `01_CURRENT_IMPLEMENTATION/v3_reference/`
- `11_MIGRATIONS_FLAT_VIEW/`

Reconstruct the actual runtime and DB contracts. Do not assume docs are authoritative over observed DB facts.

## Phase 2 — compare history and evidence

Use only when useful:

- `03_HISTORICAL_PACKAGES/`
- `04_RUNTIME_SNAPSHOTS/`
- `09_RAW_SOURCE_EXTRACTS/`

These are evidence/history, not automatic sources of truth.

## Phase 3 — product/UX identity

Use:

- `07_BRAND_ASSETS/`
- product vision documents

Do not let branding references override usability/accessibility.

## Phase 4 — first output

Before edits, return the audit requested in `00_MASTER_PROMPT_CLAUDE.md` section 37 and the subsequent execution/quality directives: current-state diagnosis, trust map, architecture reconstruction, risks, target architecture, module boundaries, P0–P4 roadmap, one-month execution plan, missing info, and implementation/validation strategy.

## Phase 5 — implementation after approval

Work incrementally, with cross-review, tests, STAGING gates and continuous maintenance of `MANUAL_ACTIONS_FOR_ISMAEL.md`.

Never touch PROD automatically.
