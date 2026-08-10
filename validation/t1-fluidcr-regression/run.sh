#!/usr/bin/env bash
# T1 — FluidCR path regression: A/B across the merged and pre-merge nodes.
#
#   TARGET_NODE=$MERGED_NODE   -> merged CRI-O   (D)
#   TARGET_NODE=$CONTROL_NODE  -> pre-merge CRI-O (control)
#
# Run it twice and diff the two results directories. Identical behaviour on both
# nodes is the pass condition; that is the evidence for the "Mode Isolation"
# claim in the progress report.
#
# usage:  TARGET_NODE=jsj-worker-1 FLUIDCR_IMAGE=... FLUIDCR_CHECKPOINT_PATH=... ./run.sh
. "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"

: "${FLUIDCR_IMAGE:?set FLUIDCR_IMAGE to the FluidCR training image}"
: "${FLUIDCR_CHECKPOINT_PATH:?set FLUIDCR_CHECKPOINT_PATH to the local checkpoint path on the node}"
TARGET_NODE="${TARGET_NODE:-$MERGED_NODE}"
export TARGET_NODE FLUIDCR_IMAGE FLUIDCR_CHECKPOINT_PATH

outdir "t1-fluidcr-${TARGET_NODE}"
HERE="$(cd "$(dirname "$0")" && pwd)"
SINCE="$(date '+%Y-%m-%d %H:%M:%S')"
info "target node = $TARGET_NODE"

step "1/4  source workload + FluidCR checkpoint"
kubectl -n "$NS" delete pod t1-fluidcr-src t1-fluidcr-restore --ignore-not-found --wait=true >/dev/null 2>&1 || true
render_manifest "$HERE/00-source-pod.yaml" | tee "$OUTDIR/source-pod.yaml" | kubectl apply -f -
wait_pod_phase t1-fluidcr-src Running; check "FluidCR source pod Running" $?
warn "trigger the FluidCR checkpoint the usual way (SIGUSR1 / REST), then press Enter"
read -r _

step "2/4  restore via CRImportCheckpointFromPath"
kubectl -n "$NS" delete pod t1-fluidcr-src --ignore-not-found --wait=true >/dev/null 2>&1 || true
render_manifest "$HERE/01-restore-pod.yaml" | tee "$OUTDIR/restore-pod.yaml" | kubectl apply -f -
wait_pod_phase t1-fluidcr-restore Running; check "FluidCR restore reached Running" $?
kubectl -n "$NS" logs t1-fluidcr-restore > "$OUTDIR/restore-pod.log" 2>&1 || true

step "3/4  GPU devices actually present in the restored container"
kubectl -n "$NS" exec t1-fluidcr-restore -c cuda-app -- nvidia-smi -L > "$OUTDIR/nvidia-smi.txt" 2>&1 || true
grep -qE '^GPU 0' "$OUTDIR/nvidia-smi.txt"
check "nvidia-smi sees a GPU inside the restored container" $?
kubectl -n "$NS" exec t1-fluidcr-restore -c cuda-app -- ls -l /dev/nvidia0 /dev/nvidiactl \
  > "$OUTDIR/dev-nodes.txt" 2>&1 || true
grep -q '/dev/nvidia0' "$OUTDIR/dev-nodes.txt"
check "/dev/nvidia0 present (this is what the CDI guard decides)" $?

step "4/4  runtime logs"
node_journal "$TARGET_NODE" "$SINCE" "$OUTDIR/crio.log"
grep -q 'CRImportCheckpointFromPath' "$OUTDIR/crio.log"
check "took the FluidCR entry point" $?
! grep -q 'gpu-cr:' "$OUTDIR/crio.log"
check "no gpu-cr staging ran for a FluidCR-only pod" $?
grep -iE 'ext-mount-map|mount.*error|criu.*(error|fail)' "$OUTDIR/crio.log" > "$OUTDIR/mount-warnings.txt" || true
[ ! -s "$OUTDIR/mount-warnings.txt" ]
check "no ext-mount-map / CRIU mount warnings (checks change #5)" $?

kubectl -n "$NS" delete pod t1-fluidcr-restore --ignore-not-found >/dev/null 2>&1 || true
finish
