#!/usr/bin/env bash
# T5 — cross-node application-level restore (the "Functional Extension" claim).
#
# READ FIRST: change #4 (app-payload-uri staging) has not been reviewed as a
# diff yet:
#     git -C ~/gpu-cr-merge/base-crio diff HEAD -- server/container_restore.go
# The checks below assume the payload is staged the way stageGPUCheckpoint
# stages the system tar. Adjust once the real implementation is known.
. "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"
: "${FLUIDCR_IMAGE:?set FLUIDCR_IMAGE}"
: "${APP_PAYLOAD:?set APP_PAYLOAD (the FluidCR payload name on the share)}"
SOURCE_NODE="${SOURCE_NODE:-$MERGED_NODE}"
RESTORE_NODE="${RESTORE_NODE:-$CONTROL_NODE}"
export FLUIDCR_IMAGE APP_PAYLOAD SOURCE_NODE RESTORE_NODE NFS_ENDPOINT NFS_PATH

outdir t5-crossnode-app
HERE="$(cd "$(dirname "$0")" && pwd)"
SINCE="$(date '+%Y-%m-%d %H:%M:%S')"
announce_journal_hint "$RESTORE_NODE" "$SINCE"
info "source = $SOURCE_NODE   restore = $RESTORE_NODE   payload = $APP_PAYLOAD"

step "1/3  payload reachable"
check "FluidCR payload on the share" test -e "${NFS_PATH}/fluidcr/${APP_PAYLOAD}"

step "2/3  restore on the other node"
kubectl -n "$NS" delete pod t5-app-restore-crossnode --ignore-not-found --wait=true >/dev/null 2>&1 || true
render_manifest "$HERE/01-restore-pod.yaml" | tee "$OUTDIR/restore-pod.yaml" | kubectl apply -f -
check "cross-node app restore reached Running" wait_pod_phase t5-app-restore-crossnode Running
check "pod landed on $RESTORE_NODE (different from $SOURCE_NODE)" test "$(pod_node t5-app-restore-crossnode)" = "$RESTORE_NODE"
kubectl -n "$NS" logs t5-app-restore-crossnode > "$OUTDIR/restore-pod.log" 2>&1 || true

step "3/3  runtime behaviour"
node_journal "$RESTORE_NODE" "$SINCE" "$OUTDIR/crio.log"
if require_journal "$OUTDIR/crio.log" "$RESTORE_NODE"; then
  check "took FluidCR's entry point (not the GCR one)" grep -q 'CRImportCheckpointFromPath' "$OUTDIR/crio.log"
  check "payload was staged onto the target node" grep -qE 'app-payload-uri|staged' "$OUTDIR/crio.log"
fi

warn "final proof is training state: confirm the run resumes from the checkpointed"
warn "step/loss rather than from scratch. Record it under $OUTDIR/."
finish
