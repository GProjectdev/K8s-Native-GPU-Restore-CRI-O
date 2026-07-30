#!/usr/bin/env bash
# GPU RESTORE benchmark for the Custom CRI-O restore path — OUR system (gcr) vs
# baseline (pure CRIUgpu). Restore-side counterpart to the checkpoint repo's run.sh.
#
# MODES (give the manifests you want to compare):
#   gcr      = restore a GCR checkpoint (.tar + external .blob): CRIU restores CPU +
#              GPU CONTROL state, then the interceptor re-maps GPU DATA from the .blob.
#   baseline = restore a pure-CRIUgpu checkpoint (one .tar, GPU data inside): CRIU +
#              cuda_plugin restore CPU + the WHOLE GPU (no interceptor, no blob remap).
#
# Phases measured per run:
#   stage_s : Custom CRI-O fetches the archive(s) onto the node (CRI-O journal)
#   criu_s  : CRIU restore (restore.log last ts)  [baseline: includes ALL GPU data]
#   cuda_s  :   ... cuda_plugin span within criu_s
#   remap_s : interceptor .blob -> GPU data remap (restore-agent journal)  [gcr only]
#   total_s : apply -> Pod Running (CRIU visible)
#   usable_s: apply -> app fully usable
#             gcr      = until restore-agent "GPU restore complete" (remap done)
#             baseline = total_s (CRIU already restored the GPU when Running)
#   -> comparison prints median per mode + (baseline_usable - gcr_usable).
#
# Run on the MASTER (kubectl). Host data is on the TARGET node -> set NODE_SSH,
# e.g. NODE_SSH="ssh jsj-worker-2". Or run on the node with kubectl and NODE_SSH="".
#
# Env:
#   GCR_YAML=deploy/restore-gcr.yaml         # OUR-system restore manifest
#   BASE_YAML=deploy/restore-baseline.yaml   # baseline restore manifest
#   (or RESTORE_YAML=... for a single gcr-only measurement, back-compat)
#   NODE_SSH="ssh jsj-worker-2"  RUNS=5  TIMEOUT=600  REMAP_TIMEOUT=120
#   OUT=restore-bench.csv  CRIO_UNIT=crio  AGENT_UNIT=gpu-cr-restore-agent
#   DATA_DIR=/var/lib/gcr-data  STAGE_DIR=/var/lib/gpu-cr/restore  KEEP_LAST=0
set -uo pipefail
GCR_YAML=${GCR_YAML:-${RESTORE_YAML:-}}
BASE_YAML=${BASE_YAML:-}
[ -n "$GCR_YAML$BASE_YAML" ] || { echo "set GCR_YAML and/or BASE_YAML (or RESTORE_YAML for gcr-only)"; exit 1; }
NODE_SSH=${NODE_SSH:-}; RUNS=${RUNS:-5}; TIMEOUT=${TIMEOUT:-600}; REMAP_TIMEOUT=${REMAP_TIMEOUT:-120}
OUT=${OUT:-restore-bench.csv}; CRIO_UNIT=${CRIO_UNIT:-crio}; AGENT_UNIT=${AGENT_UNIT:-gpu-cr-restore-agent}
DATA_DIR=${DATA_DIR:-/var/lib/gcr-data}; STAGE_DIR=${STAGE_DIR:-/var/lib/gpu-cr/restore}; KEEP_LAST=${KEEP_LAST:-0}

now(){ date +%s.%N; }
elapsed(){ awk "BEGIN{printf \"%.1f\", $(now)-$1}"; }
nrun(){ if [ -n "$NODE_SSH" ]; then $NODE_SSH "$@"; else "$@"; fi; }
delta(){ [ -n "$1" ] && [ -n "$2" ] && awk "BEGIN{printf \"%.2f\", $2-$1}"; }

parse_manifest(){   # $1=yaml -> sets M_NAME M_NS M_NODE M_CTR M_UID
  local y=$1
  M_NAME=$(awk '/^metadata:/{m=1} m&&/name:/{print $2; exit}' "$y")
  M_NS=$(awk '/namespace:/{print $2; exit}' "$y"); M_NS=${M_NS:-default}
  M_NODE=$(grep -m1 'kubernetes.io/hostname' "$y" | sed -E 's/.*hostname: *([^ }]+).*/\1/')
  M_CTR=$(awk '/containers:/{c=1} c&&/- *name:/{print $NF; exit}' "$y"); M_CTR=${M_CTR:-cuda-app}
  M_UID=$(grep -m1 'source-pod-uid' "$y" | grep -oE '[0-9a-f]{8}-[0-9a-f-]+' | head -1)
}
del_pod(){ kubectl -n "$M_NS" delete pod "$M_NAME" --force --grace-period=0 >/dev/null 2>&1 || true
  local t0; t0=$(now); while kubectl -n "$M_NS" get pod "$M_NAME" >/dev/null 2>&1; do
    awk "BEGIN{exit !($(elapsed "$t0")<60)}" || break; sleep 1; done; }
row(){ local IFS=,; echo "$*" >> "$OUT"; }
echo "mode,run,total_s,usable_s,stage_s,criu_s,cuda_plugin_s,remap_s,tar_bytes,blob_bytes,segs,phase" > "$OUT"

run_one(){   # $1=mode $2=yaml $3=idx
  local mode=$1 yaml=$2 idx=$3
  parse_manifest "$yaml"
  echo "=== [$mode r$idx] $M_NS/$M_NAME (node=${M_NODE:-?}) ==="
  del_pod
  local since; since=$(( $(date +%s) - 2 )); local t0; t0=$(now)
  kubectl -n "$M_NS" apply -f "$yaml" >/dev/null 2>&1 || { echo "  apply failed"; row "$mode" "$idx" "" "" "" "" "" "" "" "" "" ApplyError; return 0; }

  local phase="" ready=""
  while awk "BEGIN{exit !($(elapsed "$t0")<$TIMEOUT)}"; do
    ready=$(kubectl -n "$M_NS" get pod "$M_NAME" -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null || echo "")
    phase=$(kubectl -n "$M_NS" get pod "$M_NAME" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
    [ "$ready" = "true" ] && { phase="Running"; break; }
    [ "$phase" = "Failed" ] && break
    sleep 1
  done
  local total_s; total_s=$(elapsed "$t0")
  if [ "$ready" != "true" ]; then
    echo "  NOT running in ${total_s}s (phase=${phase:-?})"
    kubectl -n "$M_NS" describe pod "$M_NAME" 2>/dev/null | sed -n '/Events:/,$p' | tail -6 | sed 's/^/    /'
    row "$mode" "$idx" "$total_s" "" "" "" "" "" "" "" "" "${phase:-NotRunning}"; return 0
  fi
  local cid; cid=$(kubectl -n "$M_NS" get pod "$M_NAME" -o jsonpath='{.status.containerStatuses[0].containerID}' 2>/dev/null | sed 's#.*/##'); local cid12=${cid:0:12}

  # gcr: wait until the interceptor finishes the data remap (pod log "restore ACK sent")
  local usable_s=""
  if [ "$mode" = gcr ]; then
    local w0; w0=$(now)
    while awk "BEGIN{exit !($(elapsed "$w0")<$REMAP_TIMEOUT)}"; do
      kubectl -n "$M_NS" logs "$M_NAME" 2>/dev/null | grep -q 'restore ACK sent' && break; sleep 1
    done
  fi

  # raw host data (simple remote reads; parse locally)
  local CJ AJ RLOG tar_bytes blob_bytes
  CJ=$(nrun journalctl -u "$CRIO_UNIT" --since "@$since" -o short-unix --no-pager 2>/dev/null)
  AJ=$(nrun journalctl -u "$AGENT_UNIT" --since "@$since" -o short-unix --no-pager 2>/dev/null)
  [ -n "$cid" ] && RLOG=$(nrun cat "/run/containers/storage/overlay-containers/$cid/userdata/restore.log" 2>/dev/null)
  tar_bytes=$(nrun stat -c %s "$STAGE_DIR/$M_CTR-Checkpoint.tar" 2>/dev/null | tr -dc '0-9')
  [ "$mode" = gcr ] && blob_bytes=$(nrun stat -c %s "$DATA_DIR/$M_UID/data.blob" 2>/dev/null | tr -dc '0-9')

  local ann_ts blob_ts stage_end stage_s
  ann_ts=$(echo "$CJ" | grep -m1 'restore annotation detected' | awk '{print $1}')
  if [ "$mode" = gcr ]; then stage_end=$(echo "$CJ" | grep 'staged GPU data blob' | tail -1 | awk '{print $1}')
  else                       stage_end=$(echo "$CJ" | grep 'staged checkpoint'     | tail -1 | awk '{print $1}'); fi
  stage_s=$(delta "$ann_ts" "$stage_end")

  local criu_s cuda_s cs ce
  criu_s=$(echo "$RLOG" | awk -F'[()]' '/^\([0-9]/{t=$2} END{if(t!="")printf "%.3f", t}')
  cs=$(echo "$RLOG" | grep -m1 cuda_plugin | sed -nE 's/^\(([0-9.]+)\).*/\1/p')
  ce=$(echo "$RLOG" | grep cuda_plugin | tail -1 | sed -nE 's/^\(([0-9.]+)\).*/\1/p')
  cuda_s=$(delta "$cs" "$ce")

  local remap_s="" segs=""
  if [ "$mode" = gcr ]; then
    local rm0 rm1
    rm0=$(echo "$AJ" | grep 'remapping GPU data' | grep -F "$cid12" | tail -1 | awk '{print $1}')
    [ -z "$rm0" ] && rm0=$(echo "$AJ" | grep 'remapping GPU data' | tail -1 | awk '{print $1}')
    rm1=$(echo "$AJ" | grep 'GPU restore complete' | tail -1 | awk '{print $1}')
    remap_s=$(delta "$rm0" "$rm1")
    usable_s=$(delta "$t0" "$rm1")            # apply -> remap complete
    segs=$(kubectl -n "$M_NS" logs "$M_NAME" 2>/dev/null | grep -oE 'remap: [0-9]+ segs restored' | grep -oE '[0-9]+' | head -1)
  else
    usable_s=$total_s                          # baseline: usable when Running
  fi

  echo "  total=${total_s}s usable=${usable_s:-?}s | stage=${stage_s:-?} criu=${criu_s:-?} (cuda_plugin=${cuda_s:-?}) remap=${remap_s:-n/a} | tar=${tar_bytes:-?}B blob=${blob_bytes:-n/a}B"
  row "$mode" "$idx" "$total_s" "${usable_s:-}" "${stage_s:-}" "${criu_s:-}" "${cuda_s:-}" "${remap_s:-}" "${tar_bytes:-}" "${blob_bytes:-}" "${segs:-}" "Running"
}

declare -a JOBS
[ -n "$GCR_YAML" ]  && JOBS+=("gcr|$GCR_YAML")
[ -n "$BASE_YAML" ] && JOBS+=("baseline|$BASE_YAML")
for job in "${JOBS[@]}"; do
  mode=${job%%|*}; yaml=${job#*|}
  [ -f "$yaml" ] || { echo "[bench] $mode manifest not found: $yaml"; continue; }
  for r in $(seq 1 "$RUNS"); do run_one "$mode" "$yaml" "$r"; done
done
# leave nothing running (delete last of each)
if [ "$KEEP_LAST" != 1 ]; then for job in "${JOBS[@]}"; do parse_manifest "${job#*|}"; del_pod; done; fi

echo; echo "[bench] results -> $OUT"; column -t -s, "$OUT" 2>/dev/null || cat "$OUT"
python3 - "$OUT" <<'PYEOF'
import csv, sys, statistics
from collections import defaultdict
rows=[r for r in csv.DictReader(open(sys.argv[1])) if r.get("phase")=="Running"]
g=defaultdict(list)
for r in rows: g[r["mode"]].append(r)
def med(rs,c):
    v=[float(x[c]) for x in rs if x.get(c) not in ("",None,"?")]
    return statistics.median(v) if v else float("nan")
if not rows: print("\n[bench] no successful restores."); sys.exit(0)
print("\n[bench] MEDIAN per mode:")
print("  %-9s %8s %8s %8s %8s %8s %8s %3s"%("mode","total","usable","stage","criu","cuda_pl","remap","n"))
for m in sorted(g):
    rs=g[m]
    def f(c):
        x=med(rs,c); return "%8.2f"%x if x==x else "%8s"%"-"
    print("  %-9s %s %s %s %s %s %s %3d"%(m,f("total_s"),f("usable_s"),f("stage_s"),f("criu_s"),f("cuda_plugin_s"),f("remap_s"),len(rs)))
if "gcr" in g and "baseline" in g:
    gu=med(g["gcr"],"usable_s"); bu=med(g["baseline"],"usable_s")
    gt=med(g["gcr"],"total_s");  bt=med(g["baseline"],"total_s")
    print("\n[bench] gcr vs baseline (positive = gcr faster):")
    if gu==gu and bu==bu: print("  time-to-usable:  gcr %.2fs  baseline %.2fs  -> %+.2f s"%(gu,bu,bu-gu))
    if gt==gt and bt==bt: print("  time-to-Running: gcr %.2fs  baseline %.2fs  -> %+.2f s"%(gt,bt,bt-gt))
PYEOF
