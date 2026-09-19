import json,glob,os,re,sys
errors=[]
for f in glob.glob("n8n/*.json"):
    try:d=json.load(open(f,encoding="utf-8"))
    except Exception as e: errors.append(f"{f}: invalid json {e}"); continue
    names=[n["name"] for n in d.get("nodes",[])]
    if len(names)!=len(set(names)):errors.append(f"{f}: duplicate node names")
    ids=[n["id"] for n in d.get("nodes",[])]
    if len(ids)!=len(set(ids)):errors.append(f"{f}: duplicate ids")
    for src,c in d.get("connections",{}).items():
        if src not in names:errors.append(f"{f}: missing source {src}")
        for branch in c.get("main",[]):
            for t in branch:
                if t["node"] not in names:errors.append(f"{f}: missing target {t['node']}")
    raw=json.dumps(d)
    if "=={{" in raw:errors.append(f"{f}: malformed expression ==\\{{\\{{")
print("PASS" if not errors else "\\n".join(errors))
sys.exit(1 if errors else 0)
