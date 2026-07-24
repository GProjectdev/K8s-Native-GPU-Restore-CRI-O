#!/usr/bin/env bash
# One-shot restore benchmark over MANY checkpoints, from the MASTER, fully automatic:
#   for each checkpoint:  template -> swap name/uri/uid -> kubectl apply -> measure -> delete
#
# Why a TEMPLATE (and not per-tar generation): a restore Pod must carry the original
# container's NVIDIA driver bind-mounts. In a UNIFORM cluster (same driver on every
# node) that mount set is identical for every checkpoint, so you generate ONE reference
# manifest once (on a GPU node) and this script just swaps the 3 per-checkpoint fields.
#
#   # one-time, on a GPU node, from ANY one of your checkpoints:
#   ./scripts/gen-restore-pod.sh /mnt/nfs/gcr/<any>.tar --name r-tmpl \
#       --uid <its-uid> --node jsj-worker-2 --image <img> \
#       --uri "nfs://<server>/mnt/nfs/gcr/<any>.tar" > deploy/restore-template.yaml
#
#   # then, from the MASTER:
#   TEMPLATE=deploy/restore-template.yaml SERVER=10.178.0.14 \
#   CKPTS_FILE=ckpts.txt RUNS=3 NODE_SSH="ssh jsj-worker-2" \
#     ./benchmark/restore-suite.sh
#
# CKPTS_FILE: your status table (each line needs the source-pod-uid + the .tar path;
# a header line without a UUID is skipped). Mode (gcr/baseline) is inferred from the name.
#
# Env: TEMPLATE (req), SERVER (NFS ip, req), CKPTS_FILE (req), RUNS=3, TIMEOUT=600,
#      REMAP_TIMEOUT=120, NODE_SSH="" (phase split needs it), OUT=restore-suite.csv,
#      CRIO_UNIT=crio, AGENT_UNIT=gpu-cr-restore-agent, KUBECTL=kubectl, NS=default,
#      DATA_DIR=/var/lib/gcr-data, STAGE_DIR=/var/lib/gpu-cr/restore, KEEP_LAST=0
set -uo pipefail
TEMPLATE=${TEMPLATE:?set TEMPLATE to a reference restore manifest (gen-restore-pod.sh, once)}
SERVER=${SERVER:?set SERVER to the NFS server IP}
CKPTS_FILE=${CKPTS_FILE:?set CKPTS_FILE to your checkpoint list}
RUNS=${RUNS:-3}; TIMEOUT=${TIMEOUT:-600}; REMAP_TIMEOUT=${REMAP_TIMEOUT:-120}
NODE_SSH=${NODE_SSH:-}; OUT=${OUT:-restore-suite.csv}
CRIO_UNIT=${CRIO_UNIT:-crio}; AGENT_UNIT=${AGENT_UNIT:-gpu-cr-restore-agent}
KUBECTL=${KUBECTL:-kubectl}; NS=${NS:-default}
DATA_DIR=${DATA_DIR:-/var/lib/gcr-data}; STAGE_DIR=${STAGE_DIR:-/var/lib/gpu-cr/restore}; KEEP_LAST=${KEEP_LAST:-0}
MODELS_PATH=${MODELS_PATH:-/models}; MODELS_HOSTPATH=${MODELS_HOSTPATH:-/mnt/nfs/models}
export MODELS_PATH MODELS_HOSTPATH
[ -f "$TEMPLATE" ] || { echo "template not found: $TEMPLATE"; exit 1; }
now(){ date +%s.%N; }; elapsed(){ awk "BEGIN{printf \"%.1f\", $(now)-$1}"; }
# NOTE: </dev/null on the SSH path is REQUIRED — otherwise ssh reads the while-read
# loop's stdin (the checkpoint list) and the loop stops after the first checkpoint.
nrun(){ if [ -n "$NODE_SSH" ]; then $NODE_SSH "$@" </dev/null; else "$@"; fi; }
# nsh runs a full shell command line on the node (pipes/||/redirs allowed)
nsh(){ if [ -n "$NODE_SSH" ]; then $NODE_SSH "$1" </dev/null; else bash -lc "$1"; fi; }
DROP_CACHES=${DROP_CACHES:-0}
drop_caches(){ [ "$DROP_CACHES" = 1 ] || return 0
  nsh "sync; echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || sync" >/dev/null 2>&1 || true; }
delta(){ [ -n "$1" ] && [ -n "$2" ] && awk "BEGIN{printf \"%.2f\", $2-$1}"; }
CTR=$(awk '/containers:/{c=1} c&&/- *name:/{print $NF; exit}' "$TEMPLATE"); CTR=${CTR:-cuda-app}

# render a per-checkpoint manifest from the template (swap name/uri/uid)
render(){ # $1=name $2=uri $3=uid  -> stdout
  python3 - "$TEMPLATE" "$1" "$2" "$3" <<'PY'
import sys,yaml
tpl,name,uri,uid=sys.argv[1:5]
d=yaml.safe_load(open(tpl))
d["metadata"]["name"]=name
a=d["metadata"].setdefault("annotations",{})
a["gpu-cr.io/restore"]="true"; a["gpu-cr.io/checkpoint-uri"]=uri; a["gpu-cr.io/source-pod-uid"]=uid
# Some checkpoints bind-mount the model dir (/models); CRI-O requires every checkpoint
# mount be defined in the restore pod. Ensure it's present (harmless extra for those
# that didn't use it). Configurable via MODELS_PATH / MODELS_HOSTPATH ("" to disable).
import os
mp=os.environ.get("MODELS_PATH","/models"); mh=os.environ.get("MODELS_HOSTPATH","/mnt/nfs/models")
if mp and mh:
    c=d["spec"]["containers"][0]; vms=c.setdefault("volumeMounts",[])
    if not any(v.get("mountPath")==mp for v in vms):
        vms.append({"name":"models","mountPath":mp,"readOnly":True})
        vols=d["spec"].setdefault("volumes",[])
        if not any(v.get("name")=="models" for v in vols):
            vols.append({"name":"models","hostPath":{"path":mh}})
print(yaml.safe_dump(d,default_flow_style=False,sort_keys=False))
PY
}
del_pod(){ $KUBECTL -n "$NS" delete pod "$1" --force --grace-period=0 >/dev/null 2>&1 || true
  local t0; t0=$(now); while $KUBECTL -n "$NS" get pod "$1" >/dev/null 2>&1; do awk "BEGIN{exit !($(elapsed "$t0")<60)}"||break; sleep 1; done; }
row(){ local IFS=,; echo "$*" >> "$OUT"; }
echo "mode,model,run,total_s,usable_s,stage_s,criu_s,cuda_plugin_s,remap_s,tar_bytes,blob_bytes,phase" > "$OUT"

measure(){ # $1=mode $2=model $3=name $4=uri $5=uid $6=run
  local mode=$1 model=$2 name=$3 uri=$4 uid=$5 idx=$6
  del_pod "$name"
  drop_caches   # cold-cache stage timing when DROP_CACHES=1
  render "$name" "$uri" "$uid" | { local tmp; tmp=$(mktemp); cat > "$tmp"
    local since; since=$(( $(date +%s)-2 )); local t0; t0=$(now)
    $KUBECTL -n "$NS" apply -f "$tmp" >/dev/null 2>&1 || { echo "  [$mode $model r$idx] apply failed"; rm -f "$tmp"; row "$mode" "$model" "$idx" "" "" "" "" "" "" "" "" ApplyError; return; }
    rm -f "$tmp"
    local ready="" phase=""
    while awk "BEGIN{exit !($(elapsed "$t0")<$TIMEOUT)}"; do
      ready=$($KUBECTL -n "$NS" get pod "$name" -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null||echo "")
      phase=$($KUBECTL -n "$NS" get pod "$name" -o jsonpath='{.status.phase}' 2>/dev/null||echo "")
      [ "$ready" = true ] && { phase=Running; break; }; [ "$phase" = Failed ] && break; sleep 1
    done
    local total_s; total_s=$(elapsed "$t0")
    if [ "$ready" != true ]; then
      echo "  [$mode $model r$idx] NOT running ${total_s}s (phase=${phase:-?})"
      $KUBECTL -n "$NS" describe pod "$name" 2>/dev/null | sed -n '/Events:/,$p' | tail -6 | sed 's/^/      /'
      row "$mode" "$model" "$idx" "$total_s" "" "" "" "" "" "" "" "${phase:-NotRunning}"; del_pod "$name"; return; fi
    local cid; cid=$($KUBECTL -n "$NS" get pod "$name" -o jsonpath='{.status.containerStatuses[0].containerID}' 2>/dev/null|sed 's#.*/##'); local cid12=${cid:0:12}
    local usable_s="" ack_wall=""
    if [ "$mode" = gcr ]; then local w0; w0=$(now); while awk "BEGIN{exit !($(elapsed "$w0")<$REMAP_TIMEOUT)}"; do
        if $KUBECTL -n "$NS" logs "$name" 2>/dev/null | grep -q 'restore ACK sent'; then ack_wall=$(elapsed "$t0"); break; fi; sleep 1; done; fi
    local CJ AJ RLOG tar_bytes blob_bytes stage_s criu_s cuda_s remap_s
    CJ=$(nrun journalctl -u "$CRIO_UNIT" --since "@$since" -o short-unix --no-pager 2>/dev/null)
    AJ=$(nrun journalctl -u "$AGENT_UNIT" --since "@$since" -o short-unix --no-pager 2>/dev/null)
    if [ -n "$cid" ]; then
      RLOG=$(nsh "cat /run/containers/storage/overlay-containers/$cid/userdata/restore.log 2>/dev/null || cat /var/lib/containers/storage/overlay-containers/$cid/userdata/restore.log 2>/dev/null")
      if [ -z "$RLOG" ]; then
        local rp; rp=$(nsh "find /run/containers/storage /var/lib/containers/storage -name restore.log -mmin -3 2>/dev/null | head -1")
        [ -n "$rp" ] && RLOG=$(nsh "cat '$rp' 2>/dev/null")
      fi
    fi
    tar_bytes=$(nrun stat -c %s "$STAGE_DIR/$CTR-Checkpoint.tar" 2>/dev/null|tr -dc '0-9')
    local ann se
    ann=$(echo "$CJ"|grep -m1 'restore annotation detected'|awk '{print $1}')
    if [ "$mode" = gcr ]; then se=$(echo "$CJ"|grep 'staged GPU data blob'|tail -1|awk '{print $1}'); blob_bytes=$(nrun stat -c %s "$DATA_DIR/$uid/data.blob" 2>/dev/null|tr -dc '0-9')
    else se=$(echo "$CJ"|grep 'staged checkpoint'|tail -1|awk '{print $1}'); fi
    stage_s=$(delta "$ann" "$se")
    criu_s=$(echo "$RLOG"|awk -F'[()]' '/^\([0-9]/{t=$2} END{if(t!="")printf "%.3f",t}')
    local cs ce; cs=$(echo "$RLOG"|grep -m1 cuda_plugin|sed -nE 's/^\(([0-9.]+)\).*/\1/p'); ce=$(echo "$RLOG"|grep cuda_plugin|tail -1|sed -nE 's/^\(([0-9.]+)\).*/\1/p'); cuda_s=$(delta "$cs" "$ce")
    # fallback: derive CRIU-restore window from wall clock when restore.log is unavailable
    if [ -z "$criu_s" ] && [ -n "$stage_s" ]; then criu_s=$(awk "BEGIN{v=$total_s-$stage_s-0${remap_s:+ -$remap_s}; if(v<0)v=0; printf \"%.2f\", v}"); fi
    if [ "$mode" = gcr ]; then local r0 r1; r0=$(echo "$AJ"|grep 'remapping GPU data'|tail -1|awk '{print $1}'); r1=$(echo "$AJ"|grep 'GPU restore complete'|tail -1|awk '{print $1}'); remap_s=$(delta "$r0" "$r1"); usable_s=$(delta "$t0" "$r1"); [ -z "$usable_s" ] && usable_s="$ack_wall"; else usable_s=$total_s; fi
    echo "  [$mode $model r$idx] total=${total_s}s usable=${usable_s:-?}s stage=${stage_s:-?} criu=${criu_s:-?} remap=${remap_s:-n/a}"
    row "$mode" "$model" "$idx" "$total_s" "${usable_s:-}" "${stage_s:-}" "${criu_s:-}" "${cuda_s:-}" "${remap_s:-}" "${tar_bytes:-}" "${blob_bytes:-}" Running
    del_pod "$name"   # free the GPU before the next run/checkpoint (single-GPU nodes)
  }
}

LAST=""
while IFS= read -r line; do
  [ -z "${line// }" ] && continue
  uid=$(grep -oE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' <<<"$line"|head -1)
  tar=$(grep -oE '/[^ ]*\.tar' <<<"$line"|head -1)
  [ -n "$uid" ] && [ -n "$tar" ] || continue
  base=$(basename "$tar" .tar); pod=${base#checkpoint-}; pod=${pod%%_*}
  case "$pod" in *-gcr-*) mode=gcr;; *baseline*) mode=baseline;; *) mode=gcr;; esac
  model=$(echo "$pod"|sed -E 's/^b-(gcr|baseline)-//; s/-r[0-9]+$//')
  name=$(echo "r-$pod"|tr '._' '--'|cut -c1-58|sed 's/-*$//')
  uri="nfs://$SERVER$tar"
  # NOTE: the suite uses a TEMPLATE (no per-tar read); the CRI-O on the target node
  # fetches the tar via this nfs:// uri at restore time. So the runner does NOT need
  # the tar visible, and NODE_SSH is only for the optional phase split.
  echo "=== $mode / $model ($name) ==="
  for r in $(seq 1 "$RUNS"); do measure "$mode" "$model" "$name" "$uri" "$uid" "$r"; done
  LAST="$name"
done < "$CKPTS_FILE"
[ "$KEEP_LAST" = 1 ] || { [ -n "$LAST" ] && del_pod "$LAST"; }

echo; echo "[suite] results -> $OUT"; column -t -s, "$OUT" 2>/dev/null || cat "$OUT"
python3 - "$OUT" <<'PY'
import csv,sys,statistics
from collections import defaultdict
rows=[r for r in csv.DictReader(open(sys.argv[1])) if r.get("phase")=="Running"]
g=defaultdict(list)
for r in rows: g[(r["model"],r["mode"])].append(r)
def med(rs,c):
  v=[float(x[c]) for x in rs if x.get(c) not in ("",None,"?")]; return statistics.median(v) if v else float("nan")
if not rows: print("\n[suite] no successful restores."); sys.exit(0)
print("\n[suite] MEDIAN (usable_s = time until workload runs on the GPU):")
print("  %-14s %-9s %8s %8s %8s %8s %8s %3s"%("model","mode","total","usable","criu","cuda_pl","remap","n"))
for k in sorted(g):
  rs=g[k]; f=lambda c:(lambda m:"%8.2f"%m if m==m else "%8s"%"-")(med(rs,c))
  print("  %-14s %-9s %s %s %s %s %s %3d"%(k[0],k[1],f("total_s"),f("usable_s"),f("criu_s"),f("cuda_plugin_s"),f("remap_s"),len(rs)))
print("\n[suite] gcr vs baseline usable (positive = gcr faster):")
by=defaultdict(dict)
for (mdl,mode) in g: by[mdl][mode]=med(g[(mdl,mode)],"usable_s")
for mdl in sorted(by):
  d=by[mdl]
  if "gcr" in d and "baseline" in d and d["gcr"]==d["gcr"] and d["baseline"]==d["baseline"]:
    print("  %-14s gcr %7.2fs  baseline %7.2fs  -> %+.2f s"%(mdl,d["gcr"],d["baseline"],d["baseline"]-d["gcr"]))
PY
