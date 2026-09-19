import json, pathlib, sys
from collections import defaultdict

root = pathlib.Path(sys.argv[1] if len(sys.argv)>1 else ".")
files = sorted(root.glob("*.json"))
failed = False

def scan(obj, path=""):
    hits=[]
    if isinstance(obj, dict):
        for k,v in obj.items(): hits += scan(v, f"{path}.{k}" if path else k)
    elif isinstance(obj, list):
        for i,v in enumerate(obj): hits += scan(v, f"{path}[{i}]")
    elif isinstance(obj, str) and "=={{" in obj:
        hits.append(path)
    return hits

for p in files:
    if p.name == "MANIFEST.json": continue
    try:
        wf=json.loads(p.read_text(encoding="utf-8"))
    except Exception as e:
        print(p.name, "JSON FAIL", e); failed=True; continue
    names=[n["name"] for n in wf.get("nodes",[])]
    name_set=set(names)
    errors=[]
    if len(names)!=len(name_set): errors.append("duplicate node name")
    for src,data in wf.get("connections",{}).items():
        if src not in name_set: errors.append(f"missing source {src}")
        for branch in data.get("main",[]):
            for c in branch:
                if c["node"] not in name_set: errors.append(f"missing target {src}->{c['node']}")
    for hit in scan(wf): errors.append(f"double '=' expression at {hit}")
    for n in wf.get("nodes",[]):
        if n.get("type")=="n8n-nodes-base.postgres":
            if not n.get("parameters",{}).get("query","").strip().upper().startswith("SELECT"):
                errors.append(f"invalid postgres query in {n['name']}")
    print(p.name, "PASS" if not errors else "FAIL")
    for e in errors: print("  -",e)
    failed |= bool(errors)

sys.exit(1 if failed else 0)
