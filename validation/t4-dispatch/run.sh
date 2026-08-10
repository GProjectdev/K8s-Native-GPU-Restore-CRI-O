. "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"

# Everything is read from the newest results dir of the tests that produced it.
# Override with T0DIR / APPDIR / the individual vars if you need a specific run.
T0DIR="${T0DIR:-$(latest_result t0-checksum)}"
info "system-mode artifacts from: ${T0DIR:-<none>}"
SOURCE_POD_UID="$(prefer_env_else_artifact "${SOURCE_POD_UID:-}" "$T0DIR" source-pod-uid SOURCE_POD_UID)"
CKPT_TAR="$(prefer_env_else_artifact "${CKPT_TAR:-}" "$T0DIR" ckpt-tar CKPT_TAR)"

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
CKPT_PATH="$(prefer_env_else_artifact "${CKPT_PATH:-}" "$APPDIR" ckpt-path CKPT_PATH)"

TARGET_NODE="$MERGED_NODE"
export SOURCE_POD_UID CKPT_TAR CKPT_PATH TARGET_NODE MERGED_NODE APP_POD APP_MANIFEST

outdir t4-dispatch
register_cleanup t0-restore t1a-native-restore t1b-fluidcr-restore
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

step "1/3  system-mode pod (gpu-cr.io/restore)"
kubectl -n "$NS" delete pod t0-restore t1a-native-restore t1b-fluidcr-restore --ignore-not-found --wait=true >/dev/null 2>&1 || true
render_manifest "$ROOT/t0-checksum/02-restore-pod.yaml" | tee "$OUTDIR/system-pod.yaml" | kubectl apply -f -
check "system-mode restore Running" wait_pod_phase t0-restore Running
kubectl -n "$NS" logs t0-restore > "$OUTDIR/system-pod.log" 2>&1 || true

# Free the GPU before the second pod. One GPU per node here.
info "releasing the GPU for the application-mode pod"
kubectl -n "$NS" delete pod t0-restore --ignore-not-found --wait=true >/dev/null 2>&1 || true

step "2/3  application-mode pod (checkpoint-restore.crio.io), same binary"
info "application-mode pod = $APP_POD  (manifest: $APP_MANIFEST)"
render_manifest "$ROOT/$APP_MANIFEST" | tee "$OUTDIR/app-pod.yaml" | kubectl apply -f -
check "application-mode restore Running" wait_pod_phase "$APP_POD" Running
kubectl -n "$NS" logs "$APP_POD" > "$OUTDIR/app-pod.log" 2>&1 || true

step "3/3  log separation"
node_journal "$MERGED_NODE" "$SINCE" "$OUTDIR/crio.log"
if require_journal "$OUTDIR/crio.log" "$MERGED_NODE"; then
  # The figure has to show BOTH sides. gpu-cr: lines alone only show the system
  # path; the application pod's evidence is its container being created with no
  # gpu-cr line attached, so its CreateContainer entries belong in the same file.
  grep -E "gpu-cr:|Creating container: ${NS}/(t0-restore|${APP_POD})/|Started container" \
       "$OUTDIR/crio.log" > "$OUTDIR/dispatch.log" 2>/dev/null || true
  cat "$OUTDIR/dispatch.log"

  # 'gpu-cr: staged checkpoint' is only printed on SUCCESS. The gate firing at all
  # shows up earlier as 'gpu-cr: restore annotation detected', so check both:
  # the gate fired, and the staging completed.
  check "system pod hit the gpu-cr gate" \
        grep -q 'gpu-cr: restore annotation detected' "$OUTDIR/dispatch.log"
  check "system pod actually staged its checkpoint" \
        grep -q 'gpu-cr: staged checkpoint' "$OUTDIR/dispatch.log"
  # CRImportCheckpointFromPath is a function name CRI-O never logs at info level.
  # What identifies the application path is the container being created for that
  # pod with no gpu-cr line attached to it.
  check "application pod's container was created" \
        grep -q "Creating container: ${NS}/${APP_POD}/" "$OUTDIR/crio.log"
  grep 'gpu-cr:' "$OUTDIR/dispatch.log" 2>/dev/null | grep "$APP_POD" > "$OUTDIR/crosstalk.txt" 2>/dev/null || true
  check "no gpu-cr staging for the application-mode pod (no crosstalk)" test ! -s "$OUTDIR/crosstalk.txt"
fi

info "keep $OUTDIR/dispatch.log — this is the figure for the dispatch slide"
finish
