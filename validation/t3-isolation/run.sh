#!/usr/bin/env bash
# T3 — isolation: the merged CRI-O must not touch non-C/R workloads.
# stageGPUCheckpoint() runs at the top of EVERY CreateContainer and aborts
# container creation on error, so a bug there breaks the whole node.
. "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"
outdir t3-isolation
HERE="$(cd "$(dirname "$0")" && pwd)"
SINCE="$(date '+%Y-%m-%d %H:%M:%S')"
export MERGED_NODE

step "1/3  apply a plain GPU pod"
kubectl -n "$NS" delete pod t3-plain-gpu --ignore-not-found --wait=true >/dev/null 2>&1 || true
render_manifest "$HERE/00-plain-gpu-pod.yaml" | tee "$OUTDIR/pod.yaml" | kubectl apply -f -

step "2/3  it must simply run"
check "workload ran and printed PLAIN_OK" wait_log t3-plain-gpu 'PLAIN_OK' 240
kubectl -n "$NS" logs t3-plain-gpu > "$OUTDIR/pod.log" 2>&1 || true

step "3/3  CRI-O must not have taken the gpu-cr path"
node_journal "$MERGED_NODE" "$SINCE" "$OUTDIR/crio.log"
if require_journal "$OUTDIR/crio.log" "$MERGED_NODE"; then
  check "no 'gpu-cr:' lines for a pod without annotations" \
        not grep -q 'gpu-cr:' "$OUTDIR/crio.log"
  check "no checkpoint-archive detection triggered" \
        not grep -q 'Assuming it is a checkpoint archive' "$OUTDIR/crio.log"
fi

kubectl -n "$NS" delete pod t3-plain-gpu --ignore-not-found >/dev/null 2>&1 || true
finish
