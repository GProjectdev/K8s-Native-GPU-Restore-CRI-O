#!/usr/bin/env bash
# GPU RESTORE benchmark for the Custom CRI-O restore path (mirrors the checkpoint
# repo's benchmark/run.sh, but measures RESTORE instead of checkpoint).
#
# Repeatedly restores a checkpoint (a ready restore-Pod manifest) and breaks the
# restore wall-time into phases:
#
#   stage_s : Custom CRI-O fetches the .tar + .blob onto the node
#             (CRI-O journal: "restore annotation detected" -> "staged GPU data blob")
#   criu_s  : CRIU restores the CPU process + GPU control state (cuda_plugin)
#             (the restored container's userdata/restore.log last timestamp)
#   cuda_s  :   ... of which the NVIDIA cuda_plugin control-state restore
#   remap_s : interceptor re-maps GPU data from the .blob to the same VA (H2D)
#             (restore-agent journal: "remapping GPU data" -> "GPU restore complete")
#   total_s : wall clock from `kubectl apply` until the Pod is Running/Ready
#             (= CRIU restore visible; the app is fully usable after +remap_s)
#
# WHERE TO RUN: on the MASTER (needs kubectl). Host-side data (CRI-O journal,
# restore-agent journal, restore.log, staged files) lives on the TARGET node, so set
# NODE_SSH to reach it, e.g.  NODE_SSH="ssh jsj-worker-2".  If you run this ON the
# target node AND kubectl works there, leave NODE_SSH empty.
#
# INPUT: a ready restore-Pod manifest (scripts/gen-restore-pod.sh). Pod name/ns/node/
# container-name/source-uid are read from it.
#
# Env:
#   RESTORE_YAML=./deploy/restore-nfs.yaml   # REQUIRED
#   NODE_SSH="ssh jsj-worker-2"              # host cmd access to the target node ("" = local)
#   RUNS=5  TIMEOUT=600  OUT=restore-bench.csv
#   CRIO_UNIT=crio  AGENT_UNIT=gpu-cr-restore-agent
#   DATA_DIR=/var/lib/gcr-data  STAGE_DIR=/var/lib/gpu-cr/restore
#   KEEP_LAST=0   # 1 = leave the last restored pod running
set -uo pipefail
RESTORE_YAML=${RESTORE_YAML:?set RESTORE_YAML to a restore Pod manifest (see scripts/gen-restore-pod.sh)}
NODE_SSH=${NODE_SSH:-}
RUNS=${RUNS:-5}; TIMEOUT=${TIMEOUT:-600}; OUT=${OUT:-restore-bench.csv}
CRIO_UNIT=${CRIO_UNIT:-crio}; AGENT_UNIT=${AGENT_UNIT:-gpu-cr-restore-agent}
DATA_DIR=${DATA_DIR:-/var/lib/gcr-data}; STAGE_DIR=${STAGE_DIR:-/var/lib/gpu-cr/restore}
KEEP_LAST=${KEEP_LAST:-0}

now(){ date +%s.%N; }
elapsed(){ awk "BEGIN{printf \"%.1f\", $(now)-$1}"; }
# run a SIMPLE command on the target node; capture raw output, parse locally.
nrun(){ if [ -n "$NODE_SSH" ]; then $NODE_SSH "$@"; else "$@"; fi; }
delta(){ [ -n "$1" ] && [ -n "$2" ] && awk "BEGIN{printf \"%.2f\", $2-$1}"; }

# --- parse the manifest --------------------------------------------------------
NAME=$(awk '/^metadata:/{m=1} m&&/name:/{print $2; exit}' "$RESTORE_YAML")
NS=$(awk '/namespace:/{print $2; exit}' "$RESTORE_YAML"); NS=${NS:-default}
NODE=$(grep -m1 'kubernetes.io/hostname' "$RESTORE_YAML" | sed -E 's/.*hostname: *([^ }]+).*/\1/')
CTR=$(awk '/containers:/{c=1} c&&/- *name:/{print $NF; exit}' "$RESTORE_YAML")
SRC_UID=$(grep -m1 'source-pod-uid' "$RESTORE_YAML" | grep -oE '[0-9a-f]{8}-[0-9a-f-]+' | head -1)
[ -n "$NAME" ] || { echo "cannot read pod name from $RESTORE_YAML"; exit 1; }
CTR=${CTR:-cuda-app}
echo "[bench] pod=$NS/$NAME container=$CTR node=${NODE:-?} src-uid=${SRC_UID:-?} host=${NODE_SSH:-<local>} runs=$RUNS"
nrun journalctl -u "$CRIO_UNIT" -n1 --no-pager >/dev/null 2>&1 || \
  echo "[bench] WARN: cannot read '$CRIO_UNIT' journal on the node (set NODE_SSH / run as root) -> phase split partial"

del_pod(){ kubectl -n "$NS" delete pod "$NAME" --force --grace-period=0 >/dev/null 2>&1 || true
  local t0; t0=$(now); while kubectl -n "$NS" get pod "$NAME" >/dev/null 2>&1; do
    awk "BEGIN{exit !($(elapsed "$t0")<60)}" || break; sleep 1; done; }
row(){ local IFS=,; echo "$*" >> "$OUT"; }
echo "run,total_s,stage_s,criu_s,cuda_plugin_s,remap_s,tar_bytes,blob_bytes,segs,gpu_data_bytes,phase" > "$OUT"

run_one(){
  local idx=$1; echo "=== [restore r$idx] $NS/$NAME ==="
  del_pod
  local since; since=$(( $(date +%s) - 2 ))
  local t0; t0=$(now)
  kubectl -n "$NS" apply -f "$RESTORE_YAML" >/dev/null 2>&1 || { echo "  apply failed"; row "$idx" "" "" "" "" "" "" "" "" "" ApplyError; return 0; }
  local phase="" ready=""
  while awk "BEGIN{exit !($(elapsed "$t0")<$TIMEOUT)}"; do
    ready=$(kubectl -n "$NS" get pod "$NAME" -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null || echo "")
    phase=$(kubectl -n "$NS" get pod "$NAME" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
    [ "$ready" = "true" ] && { phase="Running"; break; }
    [ "$phase" = "Failed" ] && break
    sleep 1
  done
  local total_s; total_s=$(elapsed "$t0")
  if [ "$ready" != "true" ]; then
    echo "  NOT running in ${total_s}s (phase=${phase:-?})"
    kubectl -n "$NS" describe pod "$NAME" 2>/dev/null | sed -n '/Events:/,$p' | tail -8 | sed 's/^/    /'
    row "$idx" "$total_s" "" "" "" "" "" "" "" "" "${phase:-NotRunning}"; return 0
  fi
  local cid; cid=$(kubectl -n "$NS" get pod "$NAME" -o jsonpath='{.status.containerStatuses[0].containerID}' 2>/dev/null | sed 's#.*/##'); local cid12=${cid:0:12}

  # capture raw host-side data (simple remote commands; parse locally)
  local CJ AJ RLOG tar_bytes blob_bytes
  CJ=$(nrun journalctl -u "$CRIO_UNIT" --since "@$since" -o short-unix --no-pager 2>/dev/null)
  AJ=$(nrun journalctl -u "$AGENT_UNIT" --since "@$since" -o short-unix --no-pager 2>/dev/null)
  [ -n "$cid" ] && RLOG=$(nrun cat "/run/containers/storage/overlay-containers/$cid/userdata/restore.log" 2>/dev/null)
  tar_bytes=$(nrun stat -c %s "$STAGE_DIR/$CTR-Checkpoint.tar" 2>/dev/null | tr -dc '0-9')
  blob_bytes=$(nrun stat -c %s "$DATA_DIR/$SRC_UID/data.blob" 2>/dev/null | tr -dc '0-9')

  # stage_s = (staged GPU data blob) - (restore annotation detected)
  local ann_ts blob_ts stage_s
  ann_ts=$(echo "$CJ"  | grep -m1 'restore annotation detected' | awk '{print $1}')
  blob_ts=$(echo "$CJ" | grep 'staged GPU data blob' | tail -1 | awk '{print $1}')
  stage_s=$(delta "$ann_ts" "$blob_ts")

  # criu_s = last timestamp in restore.log ; cuda_plugin span within it
  local criu_s cuda_s cs ce
  criu_s=$(echo "$RLOG" | awk -F'[()]' '/^\([0-9]/{t=$2} END{if(t!="")printf "%.3f", t}')
  cs=$(echo "$RLOG" | grep -m1 cuda_plugin | sed -nE 's/^\(([0-9.]+)\).*/\1/p')
  ce=$(echo "$RLOG" | grep cuda_plugin | tail -1 | sed -nE 's/^\(([0-9.]+)\).*/\1/p')
  cuda_s=$(delta "$cs" "$ce")

  # remap_s from restore-agent (this container's remapping -> complete)
  local rm0 rm1 remap_s
  rm0=$(echo "$AJ" | grep 'remapping GPU data' | grep -F "$cid12" | tail -1 | awk '{print $1}')
  [ -z "$rm0" ] && rm0=$(echo "$AJ" | grep 'remapping GPU data' | tail -1 | awk '{print $1}')
  rm1=$(echo "$AJ" | grep 'GPU restore complete' | tail -1 | awk '{print $1}')
  remap_s=$(delta "$rm0" "$rm1")

  # interceptor remap stats from pod logs
  local rl segs gpu_bytes
  rl=$(kubectl -n "$NS" logs "$NAME" 2>/dev/null | grep -E 'remap: [0-9]+ segs restored' | tail -1)
  segs=$(echo "$rl" | grep -oE 'remap: [0-9]+' | grep -oE '[0-9]+')
  gpu_bytes=$(kubectl -n "$NS" logs "$NAME" 2>/dev/null | grep -oE 'freeze: [0-9]+ segs, [0-9]+ bytes' | grep -oE '[0-9]+ bytes' | grep -oE '[0-9]+' | tail -1)

  echo "  total=${total_s}s | stage=${stage_s:-?} criu=${criu_s:-?} (cuda_plugin=${cuda_s:-?}) remap=${remap_s:-?} | tar=${tar_bytes:-?}B blob=${blob_bytes:-?}B segs=${segs:-?}"
  row "$idx" "$total_s" "${stage_s:-}" "${criu_s:-}" "${cuda_s:-}" "${remap_s:-}" "${tar_bytes:-}" "${blob_bytes:-}" "${segs:-}" "${gpu_bytes:-}" "Running"
}

for r in $(seq 1 "$RUNS"); do run_one "$r"; done
[ "$KEEP_LAST" = 1 ] || del_pod
echo; echo "[bench] results -> $OUT"; column -t -s, "$OUT" 2>/dev/null || cat "$OUT"
python3 - "$OUT" <<'PYEOF'
import csv, sys, statistics
rows=[r for r in csv.DictReader(open(sys.argv[1])) if r.get("phase")=="Running"]
def med(c):
    v=[float(r[c]) for r in rows if r.get(c) not in ("",None,"?")]
    return statistics.median(v) if v else float("nan")
if not rows: print("\n[bench] no successful restores to summarize."); sys.exit(0)
print("\n[bench] MEDIAN over %d successful restore(s):"%len(rows))
for c,label in [("total_s","total (to Running)"),("stage_s","stage (tar+blob)"),
                ("criu_s","criu (cpu+control)"),("cuda_plugin_s","  cuda_plugin"),
                ("remap_s","data remap (blob->GPU)")]:
    m=med(c);  print("  %-22s %8.2f s"%(label,m)) if m==m else print("  %-22s %8s"%(label,"n/a"))
tb=med("tar_bytes"); bb=med("blob_bytes")
if tb==tb: print("  %-22s %8.2f GB"%("tar size",tb/1e9))
if bb==bb: print("  %-22s %8.2f GB"%("blob (GPU data)",bb/1e9))
PYEOF
