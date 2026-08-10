#!/usr/bin/env bash
# T5 — cross-node application-level restore (the "Functional Extension" claim).
#
# READ FIRST: change #4 (app-payload-uri staging) has not been reviewed as a diff
# yet. Before running this, read it:
#     git -C ~/gpu-cr-merge/base-crio diff HEAD -- server/container_restore.go
# The checks below assume the payload is staged the same way stageGPUCheckpoint
# stages the system tar. Adjust them once the actual implementation is known.
. "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"
: "${FLUIDCR_IMAGE:?set FLUIDCR_IMAGE}"
: "${APP_PAYLOAD:?set APP_PAYLOAD (the FluidCR payload name on the share)}"
SOURCE_NODE="${SOURCE_NODE:-$MERGED_NODE}"
RESTORE_NODE="${RESTORE_NODE:-$CONTROL_NODE}"
export FLUIDCR_IMAGE APP_PAYLOAD SOURCE_NODE RESTORE_NODE

outdir t5-crossnode-app
HERE="$(cd "$(dirname "$0")" && pwd)"
SINCE="$(date '+%Y-%m-%d %H:%M:%S')"
info "source = $SOURCE_NODE   restore = $RESTORE_NODE   payload = $APP_PAYLOAD"

step "1/3  payload reachable from the target node"
test -e "${NFS_PATH}/fluidcr/${APP_PAYLOAD}"
check "FluidCR payload on the share" $?

step "2/3  restore on the other node"
kubectl -n "$NS" delete pod t5-app-restore-crossnode --ignore-not-found --wait=true >/dev/null 2>&1 || true
render_manifest "$HERE/01-restore-pod.yaml" | tee "$OUTDIR/restore-pod.yaml" | kubectl apply -f -
wait_pod_phase t5-app-restore-crossnode Running; check "cross-node app restore reached Running" $?
[ "$(pod_node t5-app-restore-crossnode)" = "$RESTORE_NODE" ]
check "pod landed on $RESTORE_NODE (different from $SOURCE_NODE)" $?
kubectl -n "$NS" logs t5-app-restore-crossnode > "$OUTDIR/restore-pod.log" 2>&1 || true

step "3/3  runtime behaviour"
node_journal "$RESTORE_NODE" "$SINCE" "$OUTDIR/crio.log"
grep -q 'CRImportCheckpointFromPath' "$OUTDIR/crio.log"
check "took FluidCR's entry point (not the GCR one)" $?
grep -qE 'app-payload-uri|staged' "$OUTDIR/crio.log"
check "payload was staged onto the target node" $?

warn "final proof is training state: confirm the restored run resumes from the"
warn "checkpointed step/loss rather than from scratch. Record it in $OUTDIR/."
finish
