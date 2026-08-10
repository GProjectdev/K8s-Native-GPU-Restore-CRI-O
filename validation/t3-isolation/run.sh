#!/usr/bin/env bash
# T3 — isolation: the merged CRI-O must not touch non-C/R workloads.
. "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"
outdir t3-isolation
HERE="$(cd "$(dirname "$0")" && pwd)"
SINCE="$(date '+%Y-%m-%d %H:%M:%S')"

step "apply plain GPU pod"
kubectl -n "$NS" delete pod t3-plain-gpu --ignore-not-found --wait=true >/dev/null 2>&1 || true
render_manifest "$HERE/00-plain-gpu-pod.yaml" | tee "$OUTDIR/pod.yaml" | kubectl apply -f -

step "wait for completion"
wait_log t3-plain-gpu 'PLAIN_OK' 180; check "workload ran and printed PLAIN_OK" $?
kubectl -n "$NS" logs t3-plain-gpu > "$OUTDIR/pod.log" 2>&1 || true

step "CRI-O must NOT have taken the gpu-cr path"
node_journal "$MERGED_NODE" "$SINCE" "$OUTDIR/crio.log"
! grep -q 'gpu-cr:' "$OUTDIR/crio.log"
check "no 'gpu-cr:' log lines for a pod without annotations" $?
! grep -qE 'Assuming it is a checkpoint archive' "$OUTDIR/crio.log"
check "no checkpoint-archive detection triggered" $?

kubectl -n "$NS" delete pod t3-plain-gpu --ignore-not-found >/dev/null 2>&1 || true
finish
