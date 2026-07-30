#!/usr/bin/env bash
# COLD-START baseline: how long to bring a workload up FROM SCRATCH (no checkpoint) —
# deploy the workload pod, wait until it prints READY (model loaded + warmed up), measure
# apply -> READY, delete, repeat. This is the number restore is compared against.
#
# Run on the MASTER (kubectl). No node access needed (pure kubectl + pod logs).
#
# INPUT: a WORKLOAD pod manifest that loads a model and prints a line matching READY_RE
# (e.g. the offline opt-1.3b-pod.yaml — it prints "READY framework=..."). For each model
# in MODELS, the pod's name and its MODEL env are swapped.
#
# Env:
#   WORKLOAD_YAML=deploy/opt-1.3b-pod.yaml   # REQUIRED (a READY-printing loader pod)
#   MODELS="/models/gpt2 /models/gpt2-large /models/opt-1.3b /models/opt-6.7b"  # REQUIRED
#   RUNS=3  TIMEOUT=1200  READY_RE='^READY'  OUT=cold-start.csv  NS=default  KUBECTL=kubectl
#   SUITE_CSV=restore-suite.csv  # optional: also print cold-start VS restore (usable) + speedup
set -uo pipefail
WORKLOAD_YAML=${WORKLOAD_YAML:?set WORKLOAD_YAML to a workload pod that prints READY}
MODELS=${MODELS:?set MODELS to a space-separated list of MODEL values (e.g. /models/gpt2 ...)}
RUNS=${RUNS:-3}; TIMEOUT=${TIMEOUT:-1200}; READY_RE=${READY_RE:-'^READY'}
SUITE_CSV=${SUITE_CSV:-}
OUT=${OUT:-cold-start.csv}; NS=${NS:-default}; KUBECTL=${KUBECTL:-kubectl}
[ -f "$WORKLOAD_YAML" ] || { echo "workload manifest not found: $WORKLOAD_YAML"; exit 1; }
now(){ date +%s.%N; }; elapsed(){ awk "BEGIN{printf \"%.1f\", $(now)-$1}"; }

render(){ # $1=name $2=model -> stdout (set metadata.name + container MODEL env)
  python3 - "$WORKLOAD_YAML" "$1" "$2" <<'PY'
import sys,yaml
tpl,name,model=sys.argv[1:4]
d=yaml.safe_load(open(tpl))
d["metadata"]["name"]=name
d["metadata"].pop("labels",None)
c=d["spec"]["containers"][0]
env=c.setdefault("env",[])
for e in env:
    if e.get("name")=="MODEL": e["value"]=model; break
else: env.insert(0,{"name":"MODEL","value":model})
print(yaml.safe_dump(d,default_flow_style=False,sort_keys=False))
PY
}
del_pod(){ $KUBECTL -n "$NS" delete pod "$1" --force --grace-period=0 >/dev/null 2>&1 || true
  local t0; t0=$(now); while $KUBECTL -n "$NS" get pod "$1" >/dev/null 2>&1; do awk "BEGIN{exit !($(elapsed "$t0")<60)}"||break; sleep 1; done; }
row(){ local IFS=,; echo "$*" >> "$OUT"; }
echo "model,run,cold_start_s,phase" > "$OUT"

for model in $MODELS; do
  slug=$(echo "$model" | tr '/._' '---' | tr '[:upper:]' '[:lower:]' | sed 's/^-*//; s/-*$//'); slug=${slug:0:40}
  name="cold-$slug"
  echo "=== cold start / $model ($name) ==="
  for r in $(seq 1 "$RUNS"); do
    del_pod "$name"
    local_t0=$(now)
    render "$name" "$model" | $KUBECTL -n "$NS" apply -f - >/dev/null 2>&1 || { echo "  r$r apply failed"; row "$model" "$r" "" ApplyError; continue; }
    ok=""; phase=""
    while awk "BEGIN{exit !($(elapsed "$local_t0")<$TIMEOUT)}"; do
      if $KUBECTL -n "$NS" logs "$name" 2>/dev/null | grep -qE "$READY_RE"; then ok=1; break; fi
      phase=$($KUBECTL -n "$NS" get pod "$name" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
      [ "$phase" = Failed ] && break
      sleep 2
    done
    cs=$(elapsed "$local_t0")
    if [ -n "$ok" ]; then echo "  r$r READY in ${cs}s"; row "$model" "$r" "$cs" Ready
    else echo "  r$r NOT ready in ${cs}s (phase=${phase:-?})"; $KUBECTL -n "$NS" describe pod "$name" 2>/dev/null | sed -n '/Events:/,$p' | tail -6 | sed 's/^/    /'; row "$model" "$r" "$cs" "${phase:-NotReady}"; fi
    del_pod "$name"
  done
done

echo; echo "[cold] results -> $OUT"; column -t -s, "$OUT" 2>/dev/null || cat "$OUT"
python3 - "$OUT" <<'PY'
import csv,sys,statistics
from collections import defaultdict
rows=[r for r in csv.DictReader(open(sys.argv[1])) if r.get("phase")=="Ready"]
g=defaultdict(list)
for r in rows: g[r["model"]].append(float(r["cold_start_s"]))
if not rows: print("\n[cold] no successful cold starts."); sys.exit(0)
print("\n[cold] MEDIAN cold-start (apply -> READY):")
for m in sorted(g): print("  %-24s %8.1f s  (n=%d)"%(m, statistics.median(g[m]), len(g[m])))
PY

# ---- optional: cold start VS restore (usable) comparison + speedup ----
if [ -n "$SUITE_CSV" ] && [ -f "$SUITE_CSV" ]; then
python3 - "$OUT" "$SUITE_CSV" <<'PYCMP'
import csv,sys,statistics,re
from collections import defaultdict
cold_csv,suite_csv=sys.argv[1],sys.argv[2]
def key(x):
    x=x.lower(); x=re.sub(r'[/._]','-',x)
    for t in ('pytorch','facebook','models','tensorflow'): x=x.replace(t,'')
    return re.sub(r'-+','-',x).strip('-')
cm=defaultdict(list)
for r in csv.DictReader(open(cold_csv)):
    if r.get("phase")=="Ready": cm[key(r["model"])].append(float(r["cold_start_s"]))
cold={k:statistics.median(v) for k,v in cm.items()}
rm=defaultdict(list)
for r in csv.DictReader(open(suite_csv)):
    if r.get("phase")=="Running" and r.get("usable_s") not in ("",None,"?"):
        rm[(key(r["model"]),r["mode"])].append(float(r["usable_s"]))
res={k:statistics.median(v) for k,v in rm.items()}
keys=sorted(set(cold) & set(k for (k,_) in res))
if not keys:
    print("\n[compare] no overlapping models between cold-start and restore-suite (check names)."); sys.exit(0)
print("\n[compare] cold start vs restore (median usable); speedup = cold / restore:")
print("  %-14s %10s %10s %10s %9s %9s"%("model","cold(s)","base(s)","gcr(s)","cold/base","cold/gcr"))
o=open("compare-cold-vs-restore.csv","w",newline=""); w=csv.writer(o)
w.writerow(["model","cold_s","baseline_restore_s","gcr_restore_s","speedup_cold_over_baseline","speedup_cold_over_gcr"])
for k in keys:
    c=cold[k]; b=res.get((k,"baseline"),float("nan")); gg=res.get((k,"gcr"),float("nan"))
    sb=c/b if b==b and b else float("nan"); sg=c/gg if gg==gg and gg else float("nan")
    f=lambda v:("%10.1f"%v if v==v else "%10s"%"-"); fx=lambda v:("%8.1fx"%v if v==v else "%9s"%"-")
    print("  %-14s %s %s %s %s %s"%(k,f(c),f(b),f(gg),fx(sb),fx(sg)))
    w.writerow([k,round(c,1),"" if b!=b else round(b,1),"" if gg!=gg else round(gg,1),"" if sb!=sb else round(sb,1),"" if sg!=sg else round(sg,1)])
o.close(); print("\n[compare] -> compare-cold-vs-restore.csv")
PYCMP
fi
