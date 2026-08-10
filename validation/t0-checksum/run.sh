#!/usr/bin/env bash
# T0 — does the restored GPU buffer still hold the ORIGINAL bytes?
#
# This is the test that turns "restore succeeded" into "restore was correct".
# It is also the diagnostic for the v1.0-hook problem: if the poststart hook's
# step (5) times out it returns early and never runs step (6), the data.blob
# remap — the process resumes fine but the GPU data is stale. That shows up here
# as a checksum mismatch and nowhere else.
. "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"
outdir t0-checksum
HERE="$(cd "$(dirname "$0")" && pwd)"
SINCE="$(date '+%Y-%m-%d %H:%M:%S')"

step "1/5  start source workload"
kubectl -n "$NS" delete pod t0-cuda-checksum t0-restore --ignore-not-found --wait=true >/dev/null 2>&1 || true
kubectl -n "$NS" delete gpucheckpoint.gpu-cr.io t0-ckpt --ignore-not-found >/dev/null 2>&1 || true
render_manifest "$HERE/00-source-pod.yaml" | tee "$OUTDIR/source-pod.yaml" | kubectl apply -f -
wait_pod_phase t0-cuda-checksum Running
wait_log t0-cuda-checksum 'READY gpu_alloc' 300; check "source pod READY (interceptor active)" $?

kubectl -n "$NS" logs t0-cuda-checksum | grep -q 'interceptor loaded' \
  && ok "interceptor loaded" \
  || warn "no 'interceptor loaded' line — check LD_PRELOAD / libgcr-interceptor.so on this node"

BEFORE="$(pod_checksum t0-cuda-checksum)"
SOURCE_POD_UID="$(pod_uid t0-cuda-checksum)"
export SOURCE_POD_UID
info "checksum(before) = $BEFORE"
info "source pod uid   = $SOURCE_POD_UID"
echo "$BEFORE" > "$OUTDIR/checksum.before"

step "2/5  checkpoint"
kubectl apply -f "$HERE/01-gpucheckpoint.yaml"
for i in $(seq 1 150); do
  PH="$(kubectl -n "$NS" get gpucheckpoint.gpu-cr.io t0-ckpt -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  [ "$PH" = "Completed" ] && break
  sleep 2
done
[ "${PH:-}" = "Completed" ]; check "GPUCheckpoint reached Completed" $?
kubectl -n "$NS" get gpucheckpoint.gpu-cr.io t0-ckpt -o yaml > "$OUTDIR/gpucheckpoint.yaml" 2>&1 || true

step "3/5  both artifacts must exist (tar + blob)"
CKPT_TAR="$(kubectl -n "$NS" get gpucheckpoint.gpu-cr.io t0-ckpt \
             -o jsonpath='{.status.lastCheckpointPath}' 2>/dev/null | xargs -r basename || true)"
CKPT_TAR="${CKPT_TAR:-Checkpoint.tar}"
export CKPT_TAR
info "checkpoint tar = $CKPT_TAR"
test -f "/var/lib/gcr-checkpoint/${CKPT_TAR}"; check "Checkpoint.tar present" $?
test -d "/var/lib/gcr-data/${SOURCE_POD_UID}"; check "data.blob directory present (/var/lib/gcr-data/$SOURCE_POD_UID)" $?
ls -la /var/lib/gcr-checkpoint "/var/lib/gcr-data/${SOURCE_POD_UID}" > "$OUTDIR/artifacts.txt" 2>&1 || true

step "4/5  restore"
kubectl -n "$NS" delete pod t0-cuda-checksum --ignore-not-found --wait=true >/dev/null 2>&1 || true
render_manifest "$HERE/02-restore-pod.yaml" | tee "$OUTDIR/restore-pod.yaml" | kubectl apply -f -
wait_pod_phase t0-restore Running; check "restored pod reached Running" $?

step "5/5  compare"
sleep 40   # let the restored loop emit at least one fresh CHECKSUM line
kubectl -n "$NS" logs t0-restore > "$OUTDIR/restore-pod.log" 2>&1 || true
AFTER="$(pod_checksum t0-restore)"
echo "${AFTER:-<none>}" > "$OUTDIR/checksum.after"
info "checksum(after)  = ${AFTER:-<none>}"

[ -n "$AFTER" ]; check "restored pod emitted a CHECKSUM line" $?
[ "$BEFORE" = "$AFTER" ]
check "GPU tensor bytes identical before/after restore" $?

node_journal "$MERGED_NODE" "$SINCE" "$OUTDIR/crio.log"
grep -q 'gpu-cr: staged checkpoint' "$OUTDIR/crio.log"; check "CRI-O logged 'gpu-cr: staged checkpoint'" $?

if grep -q 'host helper timeout' "$OUTDIR/crio.log"; then
  bad "v1.0 hook step (5) timed out -> step (6) data.blob remap was SKIPPED"
  FAILURES=$((FAILURES+1))
fi
grep -q 'interceptor remap ack' "$OUTDIR/crio.log" \
  && ok "interceptor remap acked" \
  || warn "no 'interceptor remap ack' — if the checksum matched anyway, remap ran elsewhere; confirm where"

finish
