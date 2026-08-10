#!/usr/bin/env bash
# T1 — does CRI-O's native checkpoint/restore path still work after the merge?
#
# Of the four merged changes only ONE can affect this path: the CDI guard in
# checkpoint_utils.go's buildContainerConfig(), which both CRImportCheckpoint
# (GCR) and CRImportCheckpointFromPath (native/FluidCR) call. That guard decides
# whether the restored container gets /dev/nvidia* from the checkpoint's dumped
# spec. So the question this test answers is narrow and concrete:
#
#     after a native restore, does the container still have its GPU?
#
# No FluidCR, no leehun-criu, no GPT-2. A plain CUDA container is enough, because
# the code under test is CRI-O's, not FluidCR's.
#
# Run twice to make it an A/B:
#     TARGET_NODE=$CONTROL_NODE ./run.sh    # pre-merge binary
#     TARGET_NODE=$MERGED_NODE  ./run.sh    # merged binary
. "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"

TARGET_NODE="${TARGET_NODE:-$MERGED_NODE}"
export TARGET_NODE
outdir "t1-native-${TARGET_NODE}"
HERE="$(cd "$(dirname "$0")" && pwd)"
SINCE="$(date '+%Y-%m-%d %H:%M:%S')"
announce_journal_hint "$TARGET_NODE" "$SINCE"
info "target node = $TARGET_NODE"

step "1/5  RBAC for the kubelet checkpoint API"
kubectl apply -f "$HERE/00-rbac.yaml" >/dev/null
check "checkpoint-sa exists" kubectl -n "$NS" get sa checkpoint-sa

step "2/5  start a plain GPU container"
kubectl -n "$NS" delete pod t1-native-src t1-native-restore --ignore-not-found --wait=true >/dev/null 2>&1 || true
render_manifest "$HERE/01-source-pod.yaml" | tee "$OUTDIR/source-pod.yaml" | kubectl apply -f -
check "source pod Running" wait_pod_phase t1-native-src Running
check "workload reached MARKER" wait_log t1-native-src 'MARKER alive' 300
kubectl -n "$NS" logs t1-native-src > "$OUTDIR/source-pod.log" 2>&1 || true

SRC_DEVNODES="$(grep -m1 '^DEVNODES' "$OUTDIR/source-pod.log" || true)"
SRC_SUM="$(grep -m1 '^SUM' "$OUTDIR/source-pod.log" || true)"
info "source: $SRC_DEVNODES"
info "source: $SRC_SUM"
check "source container saw /dev/nvidia*" grep -q "/dev/nvidia" "$OUTDIR/source-pod.log"

step "3/5  checkpoint via the kubelet API"
NODE_IP="$(kubectl get node "$TARGET_NODE" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')"
info "kubelet = https://${NODE_IP}:10250"
TOKEN="$(kubectl create token checkpoint-sa --duration=1h 2>/dev/null || true)"
check "got a checkpoint-sa token" test -n "$TOKEN"

curl -sk -XPOST -H "Authorization: Bearer $TOKEN" \
  "https://${NODE_IP}:10250/checkpoint/${NS}/t1-native-src/gpu-app?timeout=600" \
  -d '{}' > "$OUTDIR/checkpoint-api.json" 2>&1 || true
cat "$OUTDIR/checkpoint-api.json"; echo

CKPT_PATH="$(python3 - "$OUTDIR/checkpoint-api.json" <<'PY'
import json,sys
try:
    d=json.load(open(sys.argv[1]))
    items=d.get("items") or []
    print(items[0] if items else "")
except Exception:
    print("")
PY
)"
export CKPT_PATH
echo "$CKPT_PATH" > "$OUTDIR/ckpt-path"
info "checkpoint tar = ${CKPT_PATH:-<none>}"
check "kubelet returned a checkpoint path" test -n "$CKPT_PATH"
if can_reach_node "$TARGET_NODE"; then
  check "tar exists on $TARGET_NODE" node_run "$TARGET_NODE" test -f "$CKPT_PATH"
else
  warn "cannot reach $TARGET_NODE — tar existence UNVERIFIED (ls $CKPT_PATH there)"
fi

step "4/5  restore via CRImportCheckpointFromPath"
kubectl -n "$NS" delete pod t1-native-src --ignore-not-found --wait=true >/dev/null 2>&1 || true
render_manifest "$HERE/02-restore-pod.yaml" | tee "$OUTDIR/restore-pod.yaml" | kubectl apply -f -
check "restored pod Running" wait_pod_phase t1-native-restore Running
sleep 15
kubectl -n "$NS" logs t1-native-restore > "$OUTDIR/restore-pod.log" 2>&1 || true

step "5/5  the actual question — does it still have a GPU?"
kubectl -n "$NS" exec t1-native-restore -c gpu-app -- ls /dev/nvidia0 /dev/nvidiactl \
  > "$OUTDIR/dev-nodes.txt" 2>&1 || true
check "/dev/nvidia0 present in the restored container" grep -q '/dev/nvidia0' "$OUTDIR/dev-nodes.txt"
check "/dev/nvidiactl present" grep -q '/dev/nvidiactl' "$OUTDIR/dev-nodes.txt"
kubectl -n "$NS" exec t1-native-restore -c gpu-app -- nvidia-smi -L > "$OUTDIR/nvidia-smi.txt" 2>&1 || true
check "nvidia-smi sees a GPU" grep -qE '^GPU 0' "$OUTDIR/nvidia-smi.txt"

# The restored process resumes mid-loop, so TICK keeps counting and no second
# MARKER/DEVNODES line appears. One lifecycle, not two.
check "process resumed (TICK continues)" grep -q '^TICK' "$OUTDIR/restore-pod.log"
check "no re-execution (single DEVNODES line)" \
      test "$(grep -c '^DEVNODES' "$OUTDIR/restore-pod.log" 2>/dev/null || echo 0)" -le 1

node_journal "$TARGET_NODE" "$SINCE" "$OUTDIR/crio.log"
if require_journal "$OUTDIR/crio.log" "$TARGET_NODE"; then
  check "took CRImportCheckpointFromPath" grep -q 'CRImportCheckpointFromPath' "$OUTDIR/crio.log"
  check "no gpu-cr staging for this pod" not grep -q 'gpu-cr:' "$OUTDIR/crio.log"
  grep -iE 'ext-mount-map|criu.*(error|fail)' "$OUTDIR/crio.log" > "$OUTDIR/mount-warnings.txt" 2>/dev/null || true
  check "no ext-mount-map / CRIU errors (probes change #5)" test ! -s "$OUTDIR/mount-warnings.txt"
fi

kubectl -n "$NS" delete pod t1-native-restore --ignore-not-found >/dev/null 2>&1 || true
finish
