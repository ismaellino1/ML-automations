import json, pathlib, re, sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
errors=[]
warnings=[]

# n8n
for f in sorted((ROOT/"n8n").glob("*.json")):
    try:
        d=json.loads(f.read_text(encoding="utf-8"))
    except Exception as e:
        errors.append(f"{f.name}: invalid JSON: {e}")
        continue
    nodes=d.get("nodes",[])
    names=[n.get("name") for n in nodes]
    ids=[n.get("id") for n in nodes]
    if len(names)!=len(set(names)): errors.append(f"{f.name}: duplicate node names")
    if len(ids)!=len(set(ids)): errors.append(f"{f.name}: duplicate node IDs")
    for src,c in d.get("connections",{}).items():
        if src not in names: errors.append(f"{f.name}: missing connection source {src}")
        for branch in c.get("main",[]):
            for t in branch:
                if t.get("node") not in names:
                    errors.append(f"{f.name}: missing connection target {t.get('node')}")
    raw=json.dumps(d,ensure_ascii=False)
    if "=={{" in raw: errors.append(f"{f.name}: malformed n8n expression ==\\{{\\{{")
    if "gpt-5.6-sol" in raw.lower(): errors.append(f"{f.name}: Sol found; Luna policy violated")
    for n in nodes:
        if n.get("type","").endswith("openAi"):
            model=((n.get("parameters") or {}).get("modelId") or {}).get("value")
            if model != "gpt-5.6-luna":
                errors.append(f"{f.name}/{n.get('name')}: unexpected model {model}")

# SQL migrations
migs=sorted((ROOT/"supabase/migrations").glob("*.sql"))
nums=[]
all_sql=""
for f in migs:
    m=re.match(r"(\d+)_",f.name)
    if m: nums.append(int(m.group(1)))
    txt=f.read_text(encoding="utf-8")
    all_sql += "\n"+txt
    if txt.count("$$") % 2:
        errors.append(f"{f.name}: unbalanced $$ quotes")
    if txt.count("$function$") % 2:
        errors.append(f"{f.name}: unbalanced $function$ quotes")
for n in range(43,58):
    if n not in nums: errors.append(f"missing migration {n:03d}")

for forbidden in [
    "REACTIVATION_POLICY_DRIVEN",
    "WAITLIST_AUTOMATION_READY",
    "TODO:",
    "NOT_IMPLEMENTED"
]:
    if forbidden in all_sql:
        errors.append(f"provisional marker found in migrations: {forbidden}")

# Required production functions
required=[
 "core.enqueue_integration_job_v1",
 "core.claim_integration_jobs_v1",
 "core.ingest_whatsapp_webhook_final",
 "core.execute_assistant_action_final",
 "core.finalize_conversation_job_final",
 "core.join_waitlist_v2",
 "core.process_waitlist_automation_v2",
 "core.enqueue_due_reminders",
 "core.enqueue_due_reactivation",
 "core.enqueue_due_campaign_jobs",
 "core.execute_control_plane_action_final",
 "core.record_automation_incident_v1",
 "core.get_ai_runtime_policy_v1",
]
for fn in required:
    if fn.lower() not in all_sql.lower():
        errors.append(f"required function missing from migrations: {fn}")

# File-level hygiene
for f in ROOT.rglob("*"):
    if f.is_file() and "__pycache__" in str(f):
        errors.append(f"runtime junk in artifact: {f}")

print("PASS" if not errors else "FAIL")
if warnings:
    print("\nWARNINGS")
    for w in warnings: print("-",w)
if errors:
    print("\nERRORS")
    for e in errors: print("-",e)
sys.exit(1 if errors else 0)
