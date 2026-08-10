#!/usr/bin/env bash
# T2 — cross-node system-level restore over nfs://.
#
# Run t0-checksum first (it produces the tar, the blob and the checksum), then
# copy both artifacts to the share and run this. Passing here is what makes the
# staging mechanism's existence justified rather than assumed.
. "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"
: "${SOURCE_POD_UID:?export SOURCE_POD_UID from the t0 run}"
: "${CHECKSUM_BEFORE:?export CHECKSUM_BEFORE from the t0 run (results/*/checksum.before)}"
RESTORE_NODE="${RESTORE_NODE:-$CONTROL_NODE}"
CKPT_TAR="${CKPT_TAR:-Checkpoint.tar}"
export SOURCE_POD_UID CKPT_TAR RESTORE_NODE

outdir t2-crossnode-system
HERE="$(cd "$(dirname "$0")" && pwd)"
SINCE="$(date '+%Y-%m-%d %H:%M:%S')"
info "source node = $MERGED_NODE   restore node = $RESTORE_NODE"
warn "RESTORE_NODE must also run the MERGED CRI-O. If it is the pre-merge control node, switch it first."

step "1/4  artifacts on the share"
info "expected:  ${NFS_PATH}/${CKPT_TAR}  and  ${NFS_PATH}/gcr-data/${SOURCE_POD_UID}/"
test -f "${NFS_PATH}/${CKPT_TAR}";                     check "tar on share" $?
test -d "${NFS_PATH}/gcr-data/${SOURCE_POD_UID}";      check "data.blob on share" $?

step "2/4  restore on the other node"
kubectl -n "$NS" delete pod t2-restore-crossnode --ignore-not-found --wait=true >/dev/null 2>&1 || true
render_manifest "$HERE/01-restore-pod.yaml" | tee "$OUTDIR/restore-pod.yaml" | kubectl apply -f -
wait_pod_phase t2-restore-crossnode Running; check "cross-node restore reached Running" $?
[ "$(pod_node t2-restore-crossnode)" = "$RESTORE_NODE" ]
check "pod actually landed on $RESTORE_NODE" $?

step "3/4  staging really happened on the target node"
node_journal "$RESTORE_NODE" "$SINCE" "$OUTDIR/crio.log"
grep -q 'gpu-cr: staged checkpoint' "$OUTDIR/crio.log"; check "target node staged the checkpoint" $?
grep -q 'nfs://' "$OUTDIR/crio.log";                    check "staged from an nfs:// URI" $?

step "4/4  value correctness"
sleep 40
kubectl -n "$NS" logs t2-restore-crossnode > "$OUTDIR/restore-pod.log" 2>&1 || true
AFTER="$(pod_checksum t2-restore-crossnode)"
info "checksum(before) = $CHECKSUM_BEFORE"
info "checksum(after)  = ${AFTER:-<none>}"
[ "$CHECKSUM_BEFORE" = "${AFTER:-}" ]
check "GPU tensor identical after CROSS-NODE restore" $?

finish
