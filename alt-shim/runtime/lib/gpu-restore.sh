#!/usr/bin/env bash
# gpu-restore.sh — GPU DATA remap after a CRIUgpu restore.
#
# main branch (CRIUgpu): the GPU CONTROL STATE and the CPU process are restored by
# CRI-O + CRIU + the NVIDIA cuda_plugin during the native CRIU restore — there is NO
# host cuda-checkpoint step here. What remains is the GCR DATA path: the in-Pod
# interceptor froze the GPU data buffers to host memory (freeing physical, keeping
# the VA) at checkpoint, so after restore they must be re-mapped (recreate physical
# + H2D to the same VA). This function just triggers that remap and waits for it.
#
# Race handling: the interceptor arms its RESTORE GATE at checkpoint *freeze* time,
# so the gate state (blocked) is captured by CRIU. The restored process therefore
# comes up already gated at its first GPU kernel launch and stays gated until this
# remap completes — no cuda-checkpoint lock/unlock is needed to hold the app.
#
# (v1.0 branch used a host cuda-checkpoint helper for control state instead.)

GCR_CONTROL_DIR="${GCR_CONTROL_DIR:-/var/lib/gpu-cr/run}"
GCR_SIGNAL_RESTORE=2
GCR_SIGNAL_IDLE=0
GCR_GPU_RESTORE_TIMEOUT="${GCR_GPU_RESTORE_TIMEOUT:-120}"

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
# The control state is already restored by CRIUgpu; this only remaps the GPU data.
gcr_gpu_restore() {
  local pid="$1" srcuid="$2"
  if [ "${GCR_GPU_RESTORE:-true}" != "true" ]; then
    gcr_log "GPU data remap disabled (GCR_GPU_RESTORE!=true)"; return 0
  fi
  [ -n "${srcuid}" ] || { gcr_log "no source-pod-uid; cannot signal interceptor remap"; return 1; }

  local ctrl; ctrl="$(gcr_ctrl_path "${srcuid}")"
  mkdir -p "$(dirname "${ctrl}")"
  gcr_log "GPU data remap: pid=${pid} ctrl=${ctrl} (control state already restored by CRIUgpu)"

  # Signal the in-Pod interceptor to remap the GPU data buffers (recreate physical
  # + map same VA + H2D). It clears its gate when done and writes GCR_IDLE.
  echo "${GCR_SIGNAL_RESTORE}" > "${ctrl}"

  if gcr_wait_control "${ctrl}" "${GCR_SIGNAL_IDLE}"; then
    gcr_log "GPU restore complete: data remapped, app resumed (pid=${pid})"; return 0
  fi
  gcr_log "WARN: remap did not ack (control!=0) within ${GCR_GPU_RESTORE_TIMEOUT}s"
  return 1
}
