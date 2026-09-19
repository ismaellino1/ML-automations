# Static validation report

- Workflow structural validator: **PASS**
- Release validator: **PASS**
- n8n workflows: **10**
- n8n nodes: **75**
- Supabase overlay migrations: **15** (`043`–`057`)
- OpenAI runtime nodes: **2**
- Default model: **gpt-5.6-luna**
- Malformed `=={{` expressions: **0**
- Provisional `WAITLIST_AUTOMATION_READY`: **0**
- Provisional `REACTIVATION_POLICY_DRIVEN`: **0**

## OpenAI nodes
- `03_ML_CONVERSATION_WORKER_PROD_FINAL.json` → `02C - IA ORQUESTRADORA` → `gpt-5.6-luna`
- `03_ML_CONVERSATION_WORKER_PROD_FINAL.json` → `06 - RESPONSE ENGINE` → `gpt-5.6-luna`

## Important
This is static validation. Provider credentials, Meta templates, Google Calendar permissions,
Supabase schema state and external API behavior still require the E2E matrix in STAGING before cutover.
