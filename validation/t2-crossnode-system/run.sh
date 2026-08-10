#!/usr/bin/env bash
# T2 — cross-node system-level restore over nfs://.
#
# Run t0-checksum first (it produces the tar, the blob and the baseline
# checksum), copy BOTH artifacts to the share, then run this. Every sample so
# far used node-local hostpath://, so this is what actually justifies staging.
. "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"
: "${SOURCE_POD_UID:?export SOURCE_POD_UID from the t0 run}"
: "${CHECKSUM_BEFORE:?export CHECKSUM_BEFORE (results/*-t0-checksum/checksum.before)}"
RESTORE_NODE="${RESTORE_NODE:-$CONTROL_NODE}"
CKPT_TAR="${CKPT_TAR:-Checkpoint.tar}"
export SOURCE_POD_UID CKPT_TAR RESTORE_NODE MERGED_NODE NFS_ENDPOINT NFS_PATH

outdir t2-crossnode-system
HERE="$(cd "$(dirname "$0")" && pwd)"
SINCE="$(date '+%Y-%m-%d %H:%M:%S')"
announce_journal_hint "$RESTORE_NODE" "$SINCE"
info "source node = $MERGED_NODE   restore node = $RESTORE_NODE"
warn "RESTORE_NODE must ALSO run the merged CRI-O. If it is still the pre-merge control node, switch it first."

step "1/4  artifacts on the share"
info "expected: ${NFS_PATH}/${CKPT_TAR}  and  ${NFS_PATH}/gcr-data/${SOURCE_POD_UID}/"
if can_reach_node "$RESTORE_NODE"; then
  check "tar on the share (as seen from $RESTORE_NODE)" \
        node_run "$RESTORE_NODE" test -f "${NFS_PATH}/${CKPT_TAR}"
  check "data.blob on the share (as seen from $RESTORE_NODE)" \
        node_run "$RESTORE_NODE" test -d "${NFS_PATH}/gcr-data/${SOURCE_POD_UID}"
else
  fail "cannot reach $RESTORE_NODE — share contents UNVERIFIED"
  warn "  check on $RESTORE_NODE:  ls -la ${NFS_PATH}/${CKPT_TAR} ${NFS_PATH}/gcr-data/${SOURCE_POD_UID}/"
fi

step "2/4  restore on the other node"
kubectl -n "$NS" delete pod t2-restore-crossnode --ignore-not-found --wait=true >/dev/null 2>&1 || true
render_manifest "$HERE/01-restore-pod.yaml" | tee "$OUTDIR/restore-pod.yaml" | kubectl apply -f -
check "cross-node restore reached Running" wait_pod_phase t2-restore-crossnode Running
check "pod actually landed on $RESTORE_NODE" test "$(pod_node t2-restore-crossnode)" = "$RESTORE_NODE"

step "3/4  staging really happened on the target node"
node_journal "$RESTORE_NODE" "$SINCE" "$OUTDIR/crio.log"
if require_journal "$OUTDIR/crio.log" "$RESTORE_NODE"; then
  check "target node staged the checkpoint" grep -q 'gpu-cr: staged checkpoint' "$OUTDIR/crio.log"
  check "staged from an nfs:// URI" grep -q 'nfs://' "$OUTDIR/crio.log"
fi

step "4/4  value correctness"
sleep 40
kubectl -n "$NS" logs t2-restore-crossnode > "$OUTDIR/restore-pod.log" 2>&1 || true
AFTER="$(pod_checksum t2-restore-crossnode)"
echo "${AFTER:-}" > "$OUTDIR/checksum.after"
info "checksum(before) = $CHECKSUM_BEFORE"
info "checksum(after)  = ${AFTER:-<none>}"
check "GPU tensor identical after CROSS-NODE restore" test "$CHECKSUM_BEFORE" = "$AFTER"

finish
