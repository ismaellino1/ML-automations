# Static validation — PROD RC1

## 01_ML_CORE_UNIVERSAL_PROD_RC1.json
- JSON parse: OK
- Nodes: 21
- Duplicate node names/IDs: OK
- Connection targets: OK
- `=={{` expressions: OK
- Postgres nodes with non-SELECT query: OK

## 02_ML_WORKER_WHATSAPP_OUTBOX_PROD_RC1.json
- JSON parse: OK
- Nodes: 6
- Duplicate node names/IDs: OK
- Connection targets: OK
- `=={{` expressions: OK
- Postgres nodes with non-SELECT query: OK

## 03_ML_WORKER_GOOGLE_CALENDAR_PROD_RC1.json
- JSON parse: OK
- Nodes: 17
- Duplicate node names/IDs: OK
- Connection targets: OK
- `=={{` expressions: OK
- Postgres nodes with non-SELECT query: OK

## 04_ML_WORKER_SCHEDULER_PROD_RC1.json
- JSON parse: OK
- Nodes: 4
- Duplicate node names/IDs: OK
- Connection targets: OK
- `=={{` expressions: OK
- Postgres nodes with non-SELECT query: OK

## 05_ML_CONTROL_PLANE_INTERNAL_ACTIONS_RC1.json
- JSON parse: OK
- Nodes: 7
- Duplicate node names/IDs: OK
- Connection targets: OK
- `=={{` expressions: OK
- Postgres nodes with non-SELECT query: OK

## 99_ML_ERROR_OBSERVABILITY_RC1.json
- JSON parse: OK
- Nodes: 3
- Duplicate node names/IDs: OK
- Connection targets: OK
- `=={{` expressions: OK
- Postgres nodes with non-SELECT query: OK

**Static result: PASS**

Static validation does not replace importing in the user's n8n version or E2E against STAGING.