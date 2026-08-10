#!/usr/bin/env bash
# T1 — FluidCR path regression: A/B across the merged and pre-merge nodes.
#
#   TARGET_NODE=$CONTROL_NODE  -> pre-merge CRI-O (baseline)
#   TARGET_NODE=$MERGED_NODE   -> merged CRI-O
# Run both, then diff the two result dirs. Agreement is the pass condition and
# the evidence for the "Mode Isolation" claim.
. "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"

: "${FLUIDCR_IMAGE:?set FLUIDCR_IMAGE to the FluidCR training image}"
: "${FLUIDCR_CHECKPOINT_PATH:?set FLUIDCR_CHECKPOINT_PATH to the local checkpoint path on the node}"
TARGET_NODE="${TARGET_NODE:-$MERGED_NODE}"
export TARGET_NODE FLUIDCR_IMAGE FLUIDCR_CHECKPOINT_PATH

outdir "t1-fluidcr-${TARGET_NODE}"
HERE="$(cd "$(dirname "$0")" && pwd)"
SINCE="$(date '+%Y-%m-%d %H:%M:%S')"
announce_journal_hint "$TARGET_NODE" "$SINCE"
info "target node = $TARGET_NODE"

step "1/4  source workload + FluidCR checkpoint"
kubectl -n "$NS" delete pod t1-fluidcr-src t1-fluidcr-restore --ignore-not-found --wait=true >/dev/null 2>&1 || true
render_manifest "$HERE/00-source-pod.yaml" | tee "$OUTDIR/source-pod.yaml" | kubectl apply -f -
check "FluidCR source pod Running" wait_pod_phase t1-fluidcr-src Running
warn "now trigger the FluidCR checkpoint the usual way (SIGUSR1 / REST), then press Enter"
read -r _

step "2/4  restore via CRImportCheckpointFromPath"
kubectl -n "$NS" delete pod t1-fluidcr-src --ignore-not-found --wait=true >/dev/null 2>&1 || true
render_manifest "$HERE/01-restore-pod.yaml" | tee "$OUTDIR/restore-pod.yaml" | kubectl apply -f -
check "FluidCR restore reached Running" wait_pod_phase t1-fluidcr-restore Running
kubectl -n "$NS" logs t1-fluidcr-restore > "$OUTDIR/restore-pod.log" 2>&1 || true

step "3/4  GPU devices inside the restored container"
kubectl -n "$NS" exec t1-fluidcr-restore -c cuda-app -- nvidia-smi -L > "$OUTDIR/nvidia-smi.txt" 2>&1 || true
check "nvidia-smi sees a GPU" grep -qE '^GPU 0' "$OUTDIR/nvidia-smi.txt"
kubectl -n "$NS" exec t1-fluidcr-restore -c cuda-app -- ls -l /dev/nvidia0 /dev/nvidiactl > "$OUTDIR/dev-nodes.txt" 2>&1 || true
check "/dev/nvidia0 present (this is what the CDI guard decides)" grep -q '/dev/nvidia0' "$OUTDIR/dev-nodes.txt"

step "4/4  runtime logs"
node_journal "$TARGET_NODE" "$SINCE" "$OUTDIR/crio.log"
if require_journal "$OUTDIR/crio.log" "$TARGET_NODE"; then
  check "took the FluidCR entry point" grep -q 'CRImportCheckpointFromPath' "$OUTDIR/crio.log"
  check "no gpu-cr staging for a FluidCR-only pod" not grep -q 'gpu-cr:' "$OUTDIR/crio.log"
  grep -iE 'ext-mount-map|mount.*error|criu.*(error|fail)' "$OUTDIR/crio.log" > "$OUTDIR/mount-warnings.txt" 2>/dev/null || true
  check "no ext-mount-map / CRIU mount warnings (probes change #5)" test ! -s "$OUTDIR/mount-warnings.txt"
fi

kubectl -n "$NS" delete pod t1-fluidcr-restore --ignore-not-found >/dev/null 2>&1 || true
finish
