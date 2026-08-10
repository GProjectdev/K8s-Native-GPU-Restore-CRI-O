#!/usr/bin/env bash
# T4 — dispatch: two annotations, two entry points, no crosstalk.
#
# The direct evidence for "both restore paths coexist in one CRI-O binary".
# Assumes T0 and T1 artifacts already exist on the node.
. "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"
: "${SOURCE_POD_UID:?run t0-checksum first and export SOURCE_POD_UID}"
: "${FLUIDCR_CHECKPOINT_PATH:?set FLUIDCR_CHECKPOINT_PATH}"
: "${FLUIDCR_IMAGE:?set FLUIDCR_IMAGE}"
CKPT_TAR="${CKPT_TAR:-Checkpoint.tar}"
TARGET_NODE="$MERGED_NODE"
export SOURCE_POD_UID CKPT_TAR TARGET_NODE FLUIDCR_CHECKPOINT_PATH FLUIDCR_IMAGE

outdir t4-dispatch
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SINCE="$(date '+%Y-%m-%d %H:%M:%S')"

step "system-mode pod"
kubectl -n "$NS" delete pod t0-restore t1-fluidcr-restore --ignore-not-found --wait=true >/dev/null 2>&1 || true
render_manifest "$ROOT/t0-checksum/02-restore-pod.yaml" | kubectl apply -f -
wait_pod_phase t0-restore Running; check "system-mode restore Running" $?

step "application-mode pod (same node, immediately after)"
render_manifest "$ROOT/t1-fluidcr-regression/01-restore-pod.yaml" | kubectl apply -f -
wait_pod_phase t1-fluidcr-restore Running; check "application-mode restore Running" $?

step "log separation"
node_journal "$MERGED_NODE" "$SINCE" "$OUTDIR/crio.log"
grep -E 'CRImportCheckpoint|CRImportCheckpointFromPath|gpu-cr:' "$OUTDIR/crio.log" \
  > "$OUTDIR/dispatch.log" || true
cat "$OUTDIR/dispatch.log"

grep -q 'gpu-cr: staged checkpoint' "$OUTDIR/dispatch.log"
check "system pod triggered gpu-cr staging" $?
grep -q 'CRImportCheckpointFromPath' "$OUTDIR/dispatch.log"
check "application pod hit CRImportCheckpointFromPath" $?

# The application pod must not appear anywhere in a gpu-cr staging line.
! grep 'gpu-cr:' "$OUTDIR/dispatch.log" | grep -q 't1-fluidcr-restore'
check "no gpu-cr staging for the application-mode pod (no crosstalk)" $?

info "keep $OUTDIR/dispatch.log — this is the figure for the dispatch slide"
finish
