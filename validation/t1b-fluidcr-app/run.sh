#!/usr/bin/env bash
# T1b — application-level checkpoint/restore, for real.
#
# This is the test the progress report's central claim actually needs. t1a only
# proves CRI-O's second entry point still works; nothing in it performs an
# application-level checkpoint. Here FluidCR does: SIGUSR1 pauses the training
# loop mid-epoch, the payload writes a state_dict, the launcher buffers it and
# drops a lock file, and only then is the container snapshotted.
#
# Judgement is one line of output: after restore, does the loop continue from
# the checkpointed step, or start over at epoch 0 step 0?
. "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"

TARGET_NODE="${TARGET_NODE:-$MERGED_NODE}"
export TARGET_NODE
outdir "t1b-fluidcr-${TARGET_NODE}"
HERE="$(cd "$(dirname "$0")" && pwd)"
SINCE="$(date '+%Y-%m-%d %H:%M:%S')"
announce_journal_hint "$TARGET_NODE" "$SINCE"
info "target node = $TARGET_NODE"

step "1/7  training pod under fluidcr-launcher"
kubectl apply -f "$HERE/00-train-script.yaml" >/dev/null
kubectl apply -f "$HERE/00-rbac.yaml" >/dev/null 2>&1 || \
  kubectl apply -f "$HERE/../t1a-native-restore/00-rbac.yaml" >/dev/null
kubectl -n "$NS" delete pod t1b-fluidcr-src t1b-fluidcr-restore --ignore-not-found --wait=true >/dev/null 2>&1 || true
render_manifest "$HERE/01-source-pod.yaml" | tee "$OUTDIR/source-pod.yaml" | kubectl apply -f -
check "source pod Running" wait_pod_phase t1b-fluidcr-src Running
check "fluidcr installed from PyPI" wait_log t1b-fluidcr-src 'FLUIDCR_INSTALLED' 600

step "2/7  training is actually progressing"
check "training started" wait_log t1b-fluidcr-src 'TRAINING_START' 300
check "steps are being emitted" wait_log t1b-fluidcr-src 'STEP epoch=[0-9]+ step=[0-9]+' 300
sleep 25    # let it get well past step 0 so a resume is distinguishable
kubectl -n "$NS" logs t1b-fluidcr-src > "$OUTDIR/source-pod.log" 2>&1 || true
LAST_STEP_LINE="$(grep -E '^STEP ' "$OUTDIR/source-pod.log" | tail -1 || true)"
info "last step before checkpoint: ${LAST_STEP_LINE:-<none>}"
echo "${LAST_STEP_LINE}" > "$OUTDIR/step.before"
LAST_STEP="$(echo "$LAST_STEP_LINE" | sed -n 's/.*step=\([0-9]*\).*/\1/p')"
check "reached a non-zero step before checkpointing" test "${LAST_STEP:-0}" -gt 0

step "3/7  APPLICATION-LEVEL checkpoint (fluidcr-ctrl)"
info "SIGUSR1 -> payload saves state_dict -> worker exits 99 -> launcher buffers + locks"
kubectl -n "$NS" exec t1b-fluidcr-src -c trainer -- \
  fluidcr-ctrl checkpoint --all > "$OUTDIR/fluidcr-ctrl.txt" 2>&1 || true
cat "$OUTDIR/fluidcr-ctrl.txt"
check "fluidcr-ctrl reported checkpoint-ready" grep -qi 'checkpoint-ready\|ready' "$OUTDIR/fluidcr-ctrl.txt"

step "4/7  the lock file is the 'safe to snapshot' signal"
kubectl -n "$NS" exec t1b-fluidcr-src -c trainer -- \
  sh -c 'ls -la /checkpoint/*/ 2>&1' > "$OUTDIR/checkpoint-dir.txt" 2>&1 || true
cat "$OUTDIR/checkpoint-dir.txt"
check "/checkpoint/<PID>/lock present" grep -q 'lock' "$OUTDIR/checkpoint-dir.txt"
check "/checkpoint/<PID>/latest.pt present (the state_dict)" grep -q 'latest.pt' "$OUTDIR/checkpoint-dir.txt"

step "5/7  container snapshot via the kubelet checkpoint API"
NODE_IP="$(kubectl get node "$TARGET_NODE" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')"
TOKEN="$(kubectl create token checkpoint-sa --duration=1h 2>/dev/null || true)"
check "got a checkpoint-sa token" test -n "$TOKEN"
curl -sk -XPOST -H "Authorization: Bearer $TOKEN" \
  "https://${NODE_IP}:10250/checkpoint/${NS}/t1b-fluidcr-src/trainer?timeout=600" \
  -d '{}' > "$OUTDIR/checkpoint-api.json" 2>&1 || true
cat "$OUTDIR/checkpoint-api.json"; echo
CKPT_PATH="$(python3 - "$OUTDIR/checkpoint-api.json" <<'PY'
import json,sys
try:
    d=json.load(open(sys.argv[1])); it=d.get("items") or []
    print(it[0] if it else "")
except Exception: print("")
PY
)"
export CKPT_PATH
echo "$CKPT_PATH" > "$OUTDIR/ckpt-path"
info "checkpoint tar = ${CKPT_PATH:-<none>}"
check "kubelet returned a checkpoint path" test -n "$CKPT_PATH"

step "6/7  restore"
kubectl -n "$NS" delete pod t1b-fluidcr-src --ignore-not-found --wait=true >/dev/null 2>&1 || true
render_manifest "$HERE/02-restore-pod.yaml" | tee "$OUTDIR/restore-pod.yaml" | kubectl apply -f -
check "restored pod Running" wait_pod_phase t1b-fluidcr-restore Running

step "7/7  THE QUESTION — does training resume, or start over?"
sleep 45
kubectl -n "$NS" logs t1b-fluidcr-restore > "$OUTDIR/restore-pod.log" 2>&1 || true
tail -20 "$OUTDIR/restore-pod.log"
echo

# Steps printed AFTER the checkpoint marker. A resume continues near LAST_STEP;
# a cold start goes back to epoch=0 step=0.
RESUMED="$(grep -E '^STEP ' "$OUTDIR/restore-pod.log" | tail -1 || true)"
echo "${RESUMED}" > "$OUTDIR/step.after"
info "before checkpoint : ${LAST_STEP_LINE:-<none>}"
info "after restore     : ${RESUMED:-<none>}"

check "restored pod emitted STEP lines" test -n "$RESUMED"
# A cold start would print TRAINING_START a second time.
check "no second TRAINING_START (not a cold start)" \
      test "$(grep -c 'TRAINING_START' "$OUTDIR/restore-pod.log" 2>/dev/null || echo 0)" -le 1
AFTER_STEP="$(echo "$RESUMED" | sed -n 's/.*step=\([0-9]*\).*/\1/p')"
check "resumed at or beyond the checkpointed step (${LAST_STEP:-?} -> ${AFTER_STEP:-?})" \
      test "${AFTER_STEP:-0}" -ge "${LAST_STEP:-1}"

node_journal "$TARGET_NODE" "$SINCE" "$OUTDIR/crio.log"
if require_journal "$OUTDIR/crio.log" "$TARGET_NODE"; then
  check "took CRImportCheckpointFromPath (application path)" \
        grep -q 'CRImportCheckpointFromPath' "$OUTDIR/crio.log"
  check "no gpu-cr staging for this pod" not grep -q 'gpu-cr:' "$OUTDIR/crio.log"
fi

kubectl -n "$NS" delete pod t1b-fluidcr-restore --ignore-not-found >/dev/null 2>&1 || true
finish
