#!/usr/bin/env bash
# T4 — dispatch: two annotations, two entry points, no crosstalk.
# The direct evidence that both restore paths coexist in one CRI-O binary.
# Assumes t0 and t1b artifacts already exist on the node.
#
# Which application-mode checkpoint this restores decides what the test proves:
#   t1b's  -> produced by a real application-level checkpoint (SIGUSR1 ->
#             state_dict), so this demonstrates two MODES coexisting
#   t1a's  -> only two CRI-O ENTRY POINTS. Weaker; say so in the write-up.
. "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"
: "${SOURCE_POD_UID:?run t0-checksum first, then export SOURCE_POD_UID}"
: "${CKPT_PATH:?export CKPT_PATH — results/*-t1b-fluidcr-*/ckpt-path (preferred) or results/*-t1a-native-*/ckpt-path}"
# Defaults target t1b. For the t1a fallback:
#   APP_POD=t1a-native-restore APP_MANIFEST=t1a-native-restore/02-restore-pod.yaml
APP_POD="${APP_POD:-t1b-fluidcr-restore}"
APP_MANIFEST="${APP_MANIFEST:-t1b-fluidcr-app/02-restore-pod.yaml}"
CKPT_TAR="${CKPT_TAR:-Checkpoint.tar}"
TARGET_NODE="$MERGED_NODE"
export SOURCE_POD_UID CKPT_TAR CKPT_PATH TARGET_NODE MERGED_NODE APP_POD APP_MANIFEST

outdir t4-dispatch
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SINCE="$(date '+%Y-%m-%d %H:%M:%S')"
announce_journal_hint "$MERGED_NODE" "$SINCE"

step "1/3  system-mode pod"
kubectl -n "$NS" delete pod t0-restore t1a-native-restore t1b-fluidcr-restore --ignore-not-found --wait=true >/dev/null 2>&1 || true
render_manifest "$ROOT/t0-checksum/02-restore-pod.yaml" | kubectl apply -f -
check "system-mode restore Running" wait_pod_phase t0-restore Running

step "2/3  application-mode pod, same node, right after"
info "application-mode pod = $APP_POD  (manifest: $APP_MANIFEST)"
render_manifest "$ROOT/$APP_MANIFEST" | kubectl apply -f -
check "application-mode restore Running" wait_pod_phase "$APP_POD" Running

step "3/3  log separation"
node_journal "$MERGED_NODE" "$SINCE" "$OUTDIR/crio.log"
if require_journal "$OUTDIR/crio.log" "$MERGED_NODE"; then
  grep -E 'CRImportCheckpoint|CRImportCheckpointFromPath|gpu-cr:' "$OUTDIR/crio.log" > "$OUTDIR/dispatch.log" 2>/dev/null || true
  cat "$OUTDIR/dispatch.log"

  check "system pod triggered gpu-cr staging" grep -q 'gpu-cr: staged checkpoint' "$OUTDIR/dispatch.log"
  check "application pod hit CRImportCheckpointFromPath" grep -q 'CRImportCheckpointFromPath' "$OUTDIR/dispatch.log"
  grep 'gpu-cr:' "$OUTDIR/dispatch.log" 2>/dev/null | grep "$APP_POD" > "$OUTDIR/crosstalk.txt" 2>/dev/null || true
  check "no gpu-cr staging for the application-mode pod (no crosstalk)" test ! -s "$OUTDIR/crosstalk.txt"
fi

info "keep $OUTDIR/dispatch.log — this is the figure for the dispatch slide"
finish
