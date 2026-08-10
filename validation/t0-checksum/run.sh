#!/usr/bin/env bash
# T0 — does the restored GPU buffer still hold the ORIGINAL bytes?
#
# Turns "restore succeeded" into "restore was correct". Also the only test that
# catches the leftover v1.0 hook: if its step (5) times out it returns before
# step (6) remaps data.blob, and the pod resumes with stale GPU memory.
. "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"
outdir t0-checksum
HERE="$(cd "$(dirname "$0")" && pwd)"
SINCE="$(date '+%Y-%m-%d %H:%M:%S')"
announce_journal_hint "$MERGED_NODE" "$SINCE"
export MERGED_NODE

step "1/5  start source workload"
kubectl -n "$NS" delete pod t0-cuda-checksum t0-restore --ignore-not-found --wait=true >/dev/null 2>&1 || true
kubectl -n "$NS" delete gpucheckpoint.gpu-cr.io t0-ckpt --ignore-not-found >/dev/null 2>&1 || true
render_manifest "$HERE/00-source-pod.yaml" | tee "$OUTDIR/source-pod.yaml" | kubectl apply -f -
check "source pod reached Running" wait_pod_phase t0-cuda-checksum Running
check "source pod printed READY (GPU allocated)" wait_log t0-cuda-checksum 'READY gpu_alloc' 300

kubectl -n "$NS" logs t0-cuda-checksum 2>/dev/null | grep -q 'interceptor loaded' \
  && ok "interceptor loaded" \
  || warn "no 'interceptor loaded' line — check LD_PRELOAD / libgcr-interceptor.so on this node"

BEFORE="$(pod_checksum t0-cuda-checksum)"
SOURCE_POD_UID="$(pod_uid t0-cuda-checksum)"
export SOURCE_POD_UID
echo "$BEFORE" > "$OUTDIR/checksum.before"
echo "$SOURCE_POD_UID" > "$OUTDIR/source-pod-uid"
info "checksum(before) = ${BEFORE:-<none>}"
info "source pod uid   = ${SOURCE_POD_UID:-<none>}"
check "baseline checksum captured" test -n "$BEFORE"

step "2/5  checkpoint"
kubectl apply -f "$HERE/01-gpucheckpoint.yaml"
PH=""
for _ in $(seq 1 150); do
  PH="$(kubectl -n "$NS" get gpucheckpoint.gpu-cr.io t0-ckpt -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  [ "$PH" = "Completed" ] && break
  sleep 2
done
check "GPUCheckpoint reached Completed (last: ${PH:-<none>})" test "$PH" = "Completed"
kubectl -n "$NS" get gpucheckpoint.gpu-cr.io t0-ckpt -o yaml > "$OUTDIR/gpucheckpoint.yaml" 2>&1 || true

step "3/5  both artifacts must exist (tar AND blob)"
CKPT_PATH="$(kubectl -n "$NS" get gpucheckpoint.gpu-cr.io t0-ckpt -o jsonpath='{.status.lastCheckpointPath}' 2>/dev/null || true)"
CKPT_TAR="$(basename "${CKPT_PATH:-Checkpoint.tar}")"
export CKPT_TAR
echo "$CKPT_TAR" > "$OUTDIR/ckpt-tar"
info "checkpoint tar = $CKPT_TAR  (from .status.lastCheckpointPath=${CKPT_PATH:-<empty>})"
check "Checkpoint.tar present" test -f "/var/lib/gcr-checkpoint/${CKPT_TAR}"
check "data.blob dir present (/var/lib/gcr-data/${SOURCE_POD_UID})" test -d "/var/lib/gcr-data/${SOURCE_POD_UID}"
ls -la /var/lib/gcr-checkpoint "/var/lib/gcr-data/${SOURCE_POD_UID}" > "$OUTDIR/artifacts.txt" 2>&1 || true

step "4/5  restore"
kubectl -n "$NS" delete pod t0-cuda-checksum --ignore-not-found --wait=true >/dev/null 2>&1 || true
render_manifest "$HERE/02-restore-pod.yaml" | tee "$OUTDIR/restore-pod.yaml" | kubectl apply -f -
check "restored pod reached Running" wait_pod_phase t0-restore Running

step "5/5  compare"
sleep 40   # the restored loop prints a fresh CHECKSUM every 30s
kubectl -n "$NS" logs t0-restore > "$OUTDIR/restore-pod.log" 2>&1 || true
AFTER="$(pod_checksum t0-restore)"
echo "${AFTER:-}" > "$OUTDIR/checksum.after"
info "checksum(after)  = ${AFTER:-<none>}"
check "restored pod emitted a CHECKSUM line" test -n "$AFTER"
check "GPU tensor bytes IDENTICAL before/after restore" test "$BEFORE" = "$AFTER"

node_journal "$MERGED_NODE" "$SINCE" "$OUTDIR/crio.log"
if require_journal "$OUTDIR/crio.log" "$MERGED_NODE"; then
  check "CRI-O logged 'gpu-cr: staged checkpoint'" grep -q 'gpu-cr: staged checkpoint' "$OUTDIR/crio.log"
  check "no 'host helper timeout' (would mean the data.blob remap was skipped)" \
        not grep -q 'host helper timeout' "$OUTDIR/crio.log"
  grep -q 'interceptor remap ack' "$OUTDIR/crio.log" \
    && ok "interceptor remap acked" \
    || warn "no 'interceptor remap ack' — if the checksum still matched, find out what remapped it"
fi

finish
