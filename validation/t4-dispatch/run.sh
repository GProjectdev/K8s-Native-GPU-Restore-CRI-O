. "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"

# Everything is read from the newest results dir of the tests that produced it.
# Override with T0DIR / APPDIR / the individual vars if you need a specific run.
T0DIR="${T0DIR:-$(latest_result t0-checksum)}"
info "system-mode artifacts from: ${T0DIR:-<none>}"
SOURCE_POD_UID="${SOURCE_POD_UID:-$(read_artifact "$T0DIR" source-pod-uid)}"
CKPT_TAR="${CKPT_TAR:-$(read_artifact "$T0DIR" ckpt-tar)}"

# Application side: prefer t1b (a real application-level checkpoint, so this test
# shows two MODES); fall back to t1a (two CRI-O ENTRY POINTS only).
APPDIR="${APPDIR:-$(latest_result 't1b-fluidcr-*')}"
if [ -n "$APPDIR" ]; then
  APP_POD="${APP_POD:-t1b-fluidcr-restore}"
  APP_MANIFEST="${APP_MANIFEST:-t1b-fluidcr-app/02-restore-pod.yaml}"
else
  APPDIR="$(latest_result 't1a-native-*')"
  APP_POD="${APP_POD:-t1a-native-restore}"
  APP_MANIFEST="${APP_MANIFEST:-t1a-native-restore/02-restore-pod.yaml}"
  warn "no t1b results — falling back to t1a. This then shows two ENTRY POINTS,"
  warn "not two MODES. Say so in the write-up."
fi
info "application-mode artifacts from: ${APPDIR:-<none>}"
CKPT_PATH="${CKPT_PATH:-$(read_artifact "$APPDIR" ckpt-path)}"

TARGET_NODE="$MERGED_NODE"
export SOURCE_POD_UID CKPT_TAR CKPT_PATH TARGET_NODE MERGED_NODE APP_POD APP_MANIFEST

outdir t4-dispatch
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

step "0/3  inputs"
info "SOURCE_POD_UID = ${SOURCE_POD_UID:-<none>}"
info "CKPT_TAR       = ${CKPT_TAR:-<none>}"
info "CKPT_PATH      = ${CKPT_PATH:-<none>}"
require_single_token SOURCE_POD_UID "$SOURCE_POD_UID" || finish
require_single_token CKPT_TAR       "$CKPT_TAR"       || finish
[ -n "$CKPT_PATH" ] || { fail "CKPT_PATH is empty — run t1b (or t1a) first"; finish; }
check "the system-mode tar exists on $MERGED_NODE" \
      node_run "$MERGED_NODE" test -f "/var/lib/gcr-checkpoint/${CKPT_TAR}"
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
