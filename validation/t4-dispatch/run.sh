#!/usr/bin/env bash
# T4 — dispatch: two annotations, two entry points, no crosstalk.
# The direct evidence that both restore paths coexist in one CRI-O binary.
# Assumes t0 and t1 artifacts already exist on the node.
. "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"
: "${SOURCE_POD_UID:?run t0-checksum first, then export SOURCE_POD_UID}"
: "${FLUIDCR_CHECKPOINT_PATH:?set FLUIDCR_CHECKPOINT_PATH}"
: "${FLUIDCR_IMAGE:?set FLUIDCR_IMAGE}"
CKPT_TAR="${CKPT_TAR:-Checkpoint.tar}"
TARGET_NODE="$MERGED_NODE"
export SOURCE_POD_UID CKPT_TAR TARGET_NODE MERGED_NODE FLUIDCR_CHECKPOINT_PATH FLUIDCR_IMAGE

outdir t4-dispatch
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SINCE="$(date '+%Y-%m-%d %H:%M:%S')"

step "1/3  system-mode pod"
kubectl -n "$NS" delete pod t0-restore t1-fluidcr-restore --ignore-not-found --wait=true >/dev/null 2>&1 || true
render_manifest "$ROOT/t0-checksum/02-restore-pod.yaml" | kubectl apply -f -
check "system-mode restore Running" wait_pod_phase t0-restore Running

step "2/3  application-mode pod, same node, right after"
render_manifest "$ROOT/t1-fluidcr-regression/01-restore-pod.yaml" | kubectl apply -f -
check "application-mode restore Running" wait_pod_phase t1-fluidcr-restore Running

step "3/3  log separation"
node_journal "$MERGED_NODE" "$SINCE" "$OUTDIR/crio.log"
if require_journal "$OUTDIR/crio.log" "$MERGED_NODE"; then
  grep -E 'CRImportCheckpoint|CRImportCheckpointFromPath|gpu-cr:' "$OUTDIR/crio.log" > "$OUTDIR/dispatch.log" 2>/dev/null || true
  cat "$OUTDIR/dispatch.log"

  check "system pod triggered gpu-cr staging" grep -q 'gpu-cr: staged checkpoint' "$OUTDIR/dispatch.log"
  check "application pod hit CRImportCheckpointFromPath" grep -q 'CRImportCheckpointFromPath' "$OUTDIR/dispatch.log"
  grep 'gpu-cr:' "$OUTDIR/dispatch.log" 2>/dev/null | grep 't1-fluidcr-restore' > "$OUTDIR/crosstalk.txt" 2>/dev/null || true
  check "no gpu-cr staging for the application-mode pod (no crosstalk)" test ! -s "$OUTDIR/crosstalk.txt"
fi

info "keep $OUTDIR/dispatch.log — this is the figure for the dispatch slide"
finish
