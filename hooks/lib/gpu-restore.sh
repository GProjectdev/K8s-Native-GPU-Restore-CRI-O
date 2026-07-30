#!/usr/bin/env bash
# gpu-restore.sh — GPU state restore after CRIU restored the CPU process.
# Mirrors (in reverse) the checkpoint engine of the
# K8s-Native-Fast-GPU-Checkpoint-Restore-System repo, and coordinates with its
# interceptor's RESTORE GATE (GCR_GATING) so the app never touches an unmapped VA.
#
# Race-free restore order (this is the crux — a naive restore then unlock crashes
# the app with CUDA_ERROR_INVALID_ARGUMENT because it runs a kernel before the
# interceptor has re-mapped the GPU data buffers):
#
#   1. cuda-checkpoint --action restore --pid P   -> control state back, state=locked
#   2. write GCR_RESTORE(2) to the interceptor control channel
#        -> interceptor raises its gate, writes GCR_GATING(3), and blocks in
#           restore_remap() (its cuMem* calls wait while 'locked')
#   3. wait for control == GCR_GATING(3)           -> gate is up, safe to unlock
#   4. cuda-checkpoint --action unlock --pid P     -> state=running; the interceptor
#        remap now proceeds, and the app's kernel launches are gated until it finishes
#   5. wait for control == GCR_IDLE(0)             -> remap done, gate released, app runs
#
# cuda-checkpoint is invoked directly on the host (this hook runs on the host, so
# there is no in-container glibc ABI issue). CUDA_CHECKPOINT_BIN overrides the path.

CUDA_CHECKPOINT_BIN="${CUDA_CHECKPOINT_BIN:-/usr/bin/cuda-checkpoint}"
GCR_CONTROL_DIR="${GCR_CONTROL_DIR:-/var/lib/gpu-cr/run}"
GCR_SIGNAL_RESTORE=2
GCR_SIGNAL_IDLE=0
GCR_SIGNAL_GATING=3
GCR_GPU_RESTORE_TIMEOUT="${GCR_GPU_RESTORE_TIMEOUT:-120}"

# Find the CUDA process to act on: the given pid or a descendant that
# cuda-checkpoint recognizes (get-state succeeds only for a real CUDA process).
gcr_find_cuda_pid() {
  local root="$1" p
  if "${CUDA_CHECKPOINT_BIN}" --get-state --pid "${root}" >/dev/null 2>&1; then echo "${root}"; return 0; fi
  for p in $(ls /proc 2>/dev/null | grep -E '^[0-9]+$'); do
    local ppid; ppid="$(awk '/^PPid:/{print $2; exit}' "/proc/$p/status" 2>/dev/null)"
    [ "${ppid}" = "${root}" ] || continue
    if "${CUDA_CHECKPOINT_BIN}" --get-state --pid "${p}" >/dev/null 2>&1; then echo "${p}"; return 0; fi
  done
  echo "${root}"
}

gcr_ctrl_path() { echo "${GCR_CONTROL_DIR}/$1/control"; }

gcr_wait_control() {  # <ctrl-file> <target-value>
  local ctrl="$1" want="$2" deadline=$(( $(date +%s) + GCR_GPU_RESTORE_TIMEOUT ))
  while [ "$(date +%s)" -lt "${deadline}" ]; do
    local v; v="$(cat "${ctrl}" 2>/dev/null | tr -d '[:space:]')"
    [ "${v}" = "${want}" ] && return 0
    sleep 0.05
  done
  return 1
}

# gcr_gpu_restore <container-init-pid> <source-pod-uid>
gcr_gpu_restore() {
  local pid="$1" srcuid="$2"
  if [ "${GCR_GPU_RESTORE:-true}" != "true" ]; then
    gcr_log "GPU restore disabled (GCR_GPU_RESTORE!=true); CRIU-only restore"; return 0
  fi
  [ "${pid:-0}" -gt 0 ] 2>/dev/null || { gcr_log "no restored pid; skipping GPU restore"; return 1; }
  [ -n "${srcuid}" ] || { gcr_log "no source-pod-uid; cannot signal interceptor remap"; return 1; }

  local gpupid; gpupid="$(gcr_find_cuda_pid "${pid}")"
  local ctrl; ctrl="$(gcr_ctrl_path "${srcuid}")"
  mkdir -p "$(dirname "${ctrl}")"
  gcr_log "GPU restore: cuda pid=${gpupid} ctrl=${ctrl}"

  # 1) control-state restore (checkpointed -> locked)
  if ! "${CUDA_CHECKPOINT_BIN}" --action restore --pid "${gpupid}" 2>&1; then
    gcr_log "cuda-checkpoint restore failed (pid=${gpupid})"; return 1
  fi
  gcr_log "control state restored (locked)"

  # 2) tell the interceptor to remap; it raises the gate and writes GCR_GATING
  echo "${GCR_SIGNAL_RESTORE}" > "${ctrl}"

  # 3) wait for the gate to be up before unlocking (avoids app-vs-remap race)
  if ! gcr_wait_control "${ctrl}" "${GCR_SIGNAL_GATING}"; then
    gcr_log "WARN: interceptor did not raise gate (GCR_GATING); unlocking anyway"
  else
    gcr_log "interceptor gate up (GCR_GATING); unlocking"
  fi

  # 4) unlock: app resumes but is gated at kernel launch; remap proceeds
  if ! "${CUDA_CHECKPOINT_BIN}" --action unlock --pid "${gpupid}" 2>&1; then
    gcr_log "cuda-checkpoint unlock failed (pid=${gpupid})"; return 1
  fi

  # 5) wait for remap completion (gate released)
  if gcr_wait_control "${ctrl}" "${GCR_SIGNAL_IDLE}"; then
    gcr_log "GPU restore complete: data remapped, app resumed (pid=${gpupid})"; return 0
  fi
  gcr_log "WARN: remap did not ack (control!=0) within ${GCR_GPU_RESTORE_TIMEOUT}s"
  return 1
}
