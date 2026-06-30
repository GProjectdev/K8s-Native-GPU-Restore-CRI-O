#!/usr/bin/env bash
# gpu-restore.sh — steps 5/6/7: put the GPU state back after CRIU restored the
# CPU process. Mirrors (in reverse) the checkpoint engine of the
# K8s-Native-Fast-GPU-Checkpoint-Restore-System repo.
#
# Why this ordering is safe: the process was checkpointed while CUDA was
# SUSPENDED (cuda-checkpoint evicted the control state to host). After CRIU
# restore the process is running again but its next CUDA call BLOCKS until the
# control state is restored. That gives us a safe window to:
#   (5) restore the CUDA control state onto the device, then
#   (6) remap the GPU data buffers to the SAME virtual addresses (H2D),
# after which (7) the app's CUDA calls unblock with valid device pointers.
#
# (5) is delegated to the SAME host helper the checkpoint side uses
#     (gpu-cr-cuda-helper.service): in-container cuda-checkpoint stack-smashes on
#     a glibc ABI mismatch, so a host service runs it natively against the real
#     GPU PID in the container subtree.
# (6) is triggered by writing the GCR_RESTORE signal (2) to the interceptor's
#     control channel, keyed by the SOURCE pod UID (CRIU restores the original
#     env, so the in-Pod interceptor watches the original GCR_POD_UID path).

GCR_CUDA_HELPER_DIR="${GCR_CUDA_HELPER_DIR:-/var/lib/gpu-cr/cuda-req}"
GCR_CONTROL_DIR="${GCR_CONTROL_DIR:-/var/lib/gpu-cr/run}"
GCR_SIGNAL_RESTORE=2
GCR_SIGNAL_IDLE=0
GCR_GPU_RESTORE_TIMEOUT="${GCR_GPU_RESTORE_TIMEOUT:-120}"

# gcr_gpu_restore <host-pid> <source-pod-uid>
gcr_gpu_restore() {
  local pid="$1" srcuid="$2"
  if [ "${GCR_GPU_RESTORE:-true}" != "true" ]; then
    gcr_log "GPU restore disabled (GCR_GPU_RESTORE!=true); CRIU-only restore"
    return 0
  fi
  [ "${pid:-0}" -gt 0 ] 2>/dev/null || { gcr_log "no restored pid; skipping GPU restore"; return 1; }

  # (5) control-state restore via the host helper (request/response files).
  gcr_cuda_helper_restore "${pid}" || return 1

  # (6) data-buffer remap: signal the in-Pod interceptor (same VA + H2D).
  if [ -n "${srcuid}" ]; then
    gcr_signal_interceptor "${srcuid}" || gcr_log "WARN: interceptor remap signal/ack failed"
  else
    gcr_log "no source-pod-uid annotation; skipping interceptor remap (CRIU-only data)"
  fi

  gcr_log "GPU restore complete for pid=${pid}"
  return 0
}

gcr_cuda_helper_restore() {
  local pid="$1"
  mkdir -p "${GCR_CUDA_HELPER_DIR}"
  local id="${pid}-$(date +%s%N)"
  local req="${GCR_CUDA_HELPER_DIR}/${id}.req"
  local res="${GCR_CUDA_HELPER_DIR}/${id}.res"
  # Helper protocol (mirror of the checkpoint repo's host helper): "restore <pid>".
  echo "restore ${pid}" > "${req}"
  gcr_log "cuda-checkpoint restore delegated to host helper (pid=${pid})"
  local deadline=$(( $(date +%s) + GCR_GPU_RESTORE_TIMEOUT ))
  while [ "$(date +%s)" -lt "${deadline}" ]; do
    if [ -f "${res}" ]; then
      local rc; rc="$(head -n1 "${res}" | tr -d '[:space:]')"
      rm -f "${res}"
      [ "${rc}" = "0" ] && { gcr_log "host helper restore ok"; return 0; }
      gcr_log "host helper restore rc=${rc}"; return 1
    fi
    sleep 0.2
  done
  rm -f "${req}"
  gcr_log "host helper timeout; is gpu-cr-cuda-helper.service running?"
  return 1
}

gcr_signal_interceptor() {
  local uid="$1"
  local dir="${GCR_CONTROL_DIR}/${uid}"
  local ctrl="${dir}/control"
  mkdir -p "${dir}"
  echo "${GCR_SIGNAL_RESTORE}" > "${ctrl}"
  gcr_log "interceptor remap signal (${GCR_SIGNAL_RESTORE}) -> ${ctrl}"
  local deadline=$(( $(date +%s) + GCR_GPU_RESTORE_TIMEOUT ))
  while [ "$(date +%s)" -lt "${deadline}" ]; do
    local v; v="$(cat "${ctrl}" 2>/dev/null | tr -d '[:space:]')"
    [ -z "${v}" ] || [ "${v}" = "${GCR_SIGNAL_IDLE}" ] && { gcr_log "interceptor remap ack"; return 0; }
    sleep 0.05
  done
  return 1
}
