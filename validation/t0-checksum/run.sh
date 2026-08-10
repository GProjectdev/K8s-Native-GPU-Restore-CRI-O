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
# The first CHECKSUM line trails READY by a second or two (sha256 over 512 MiB),
# so wait for it explicitly instead of racing it.
check "source pod emitted its first CHECKSUM" wait_log t0-cuda-checksum 'CHECKSUM [0-9a-f]{64}' 120

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
# These paths live on $MERGED_NODE, not wherever this script runs.
if can_reach_node "$MERGED_NODE"; then
  check "Checkpoint.tar present on $MERGED_NODE" \
        node_run "$MERGED_NODE" test -f "/var/lib/gcr-checkpoint/${CKPT_TAR}"
  check "data.blob dir present on $MERGED_NODE (/var/lib/gcr-data/${SOURCE_POD_UID})" \
        node_run "$MERGED_NODE" test -d "/var/lib/gcr-data/${SOURCE_POD_UID}"
  node_run "$MERGED_NODE" ls -la /var/lib/gcr-checkpoint "/var/lib/gcr-data/${SOURCE_POD_UID}" \
        > "$OUTDIR/artifacts.txt" 2>&1 || true
else
  fail "cannot reach $MERGED_NODE — artifact presence UNVERIFIED"
  warn "  a complete checkpoint is tar + blob; the blob is NOT inside the tar."
  warn "  verify by hand on $MERGED_NODE:"
  warn "    ls -la /var/lib/gcr-checkpoint/${CKPT_TAR}"
  warn "    ls -la /var/lib/gcr-data/${SOURCE_POD_UID}/"
fi

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

# A matching checksum alone is not proof: if the workload had simply re-run from
# scratch it would recompute the same deterministic tensor. What rules that out
# is the SHAPE of the restored container's log.
#
# CRI-O restores the container's log along with the process, so the pre-checkpoint
# lines (interceptor init, vmm-alloc, READY) are EXPECTED to be present. A re-run
# would show them TWICE. One lifecycle = genuine restore.
check "interceptor initialised exactly once (no re-execution)" \
      test "$(grep -c 'interceptor loaded' "$OUTDIR/restore-pod.log" 2>/dev/null || echo 0)" = "1"
check "interceptor froze the GPU buffers out to the external blob" \
      grep -q 'engine..freeze:' "$OUTDIR/restore-pod.log"
check "interceptor remapped them back to the same VA with 0 failures" \
      grep -qE 'engine..remap:.*0 failed' "$OUTDIR/restore-pod.log"
check "two CHECKSUM lines — one before the freeze, one after the remap" \
      test "$(grep -c 'CHECKSUM ' "$OUTDIR/restore-pod.log" 2>/dev/null || echo 0)" -ge 2
grep -E 'engine..(freeze|remap):' "$OUTDIR/restore-pod.log" > "$OUTDIR/gcr-engine.log" 2>/dev/null || true

node_journal "$MERGED_NODE" "$SINCE" "$OUTDIR/crio.log"
if require_journal "$OUTDIR/crio.log" "$MERGED_NODE"; then
  check "CRI-O logged 'gpu-cr: staged checkpoint'" grep -q 'gpu-cr: staged checkpoint' "$OUTDIR/crio.log"
  check "no 'host helper timeout' (would mean the data.blob remap was skipped)" \
        not grep -q 'host helper timeout' "$OUTDIR/crio.log"
  # The remap ACK is emitted by the in-Pod interceptor, not by CRI-O, so it lives
  # in the pod log (checked above) rather than the journal. Nothing to assert here.
fi

finish
