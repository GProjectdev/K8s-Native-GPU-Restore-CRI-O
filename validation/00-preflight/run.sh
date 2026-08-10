#!/usr/bin/env bash
# Preflight — confirm the node is in the state the tests assume.
# Run ON the merged node (or with ssh access to it).
. "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"
outdir preflight
step "CRIUgpu toolchain"

CP="$(ls /usr/lib/criu/cuda_plugin.so /usr/local/lib/criu/cuda_plugin.so 2>/dev/null | head -1 || true)"
[ -n "$CP" ]; check "cuda_plugin.so present (${CP:-missing})" $?

criu --version > "$OUTDIR/criu.txt" 2>&1 || true
grep -qE 'Version:[[:space:]]*4\.[2-9]' "$OUTDIR/criu.txt"; check "CRIU >= 4.2" $?

crun --version > "$OUTDIR/crun.txt" 2>&1 || true
grep -qE 'crun version 1\.(2[6-9]|[3-9][0-9])' "$OUTDIR/crun.txt"; check "crun >= 1.26" $?
grep -q '+CRIU' "$OUTDIR/crun.txt"; check "crun built with +CRIU" $?

step "CRIU options"
cp /etc/criu/default.conf "$OUTDIR/criu-default.conf" 2>/dev/null || true
grep -q 'tcp-close' /etc/criu/default.conf 2>/dev/null
check "tcp-close in /etc/criu/default.conf (needed for workloads with live TCP)" $?

step "v1.0 leftovers (CRIUgpu makes the host-helper step obsolete)"
if [ -f /usr/local/lib/gpu-cr-restore/oci-hooks/gpu-cr-restore.json ]; then
  warn "v1.0 poststart hook is INSTALLED"
  if systemctl is-active --quiet gpu-cr-cuda-helper.service; then
    info "  gpu-cr-cuda-helper.service is ACTIVE -> hook step (5) will succeed, (6) will run"
  else
    bad  "  gpu-cr-cuda-helper.service is NOT active"
    bad  "  -> hook step (5) times out (120s) and RETURNS EARLY, so step (6)"
    bad  "     (data.blob remap) is SKIPPED. GPU data would NOT be restored."
    FAILURES=$((FAILURES+1))
  fi
else
  ok "no v1.0 poststart hook installed"
fi
crio config 2>/dev/null | grep -A6 hooks_dir > "$OUTDIR/hooks_dir.txt" || true

step "CDI"
nvidia-ctk cdi list > "$OUTDIR/cdi-list.txt" 2>&1 || echo "(nvidia-ctk unavailable)" > "$OUTDIR/cdi-list.txt"
ls /etc/cdi/ /var/run/cdi/ >> "$OUTDIR/cdi-list.txt" 2>&1 || true
if grep -qE 'nvidia\.com/gpu=' "$OUTDIR/cdi-list.txt" 2>/dev/null; then
  info "CDI IS in use -> the checkpoint_utils.go guard is a no-op here"
else
  info "CDI NOT in use -> the checkpoint_utils.go guard is LOAD-BEARING (devices come from the checkpoint)"
fi

step "CRI-O"
crio config 2>/dev/null | grep -E 'enable_criu_support' > "$OUTDIR/crio-criu.txt" || true
grep -q 'true' "$OUTDIR/crio-criu.txt"; check "enable_criu_support = true" $?

finish
