#!/usr/bin/env bash
# Preflight — is this node in the state the rest of the suite assumes?
# Run ON the merged node. Read-only: touches nothing, changes nothing.
. "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"
outdir preflight

step "1/5  CRIUgpu toolchain"
CP="$(ls /usr/lib/criu/cuda_plugin.so /usr/local/lib/criu/cuda_plugin.so 2>/dev/null | head -1 || true)"
check "cuda_plugin.so present  (${CP:-NOT FOUND})" test -n "$CP"

criu --version > "$OUTDIR/criu.txt" 2>&1 || true
check "CRIU >= 4.2  ($(head -1 "$OUTDIR/criu.txt"))" \
      grep -qE 'Version:[[:space:]]*4\.([2-9]|[1-9][0-9])' "$OUTDIR/criu.txt"

crun --version > "$OUTDIR/crun.txt" 2>&1 || true
check "crun >= 1.26  ($(head -1 "$OUTDIR/crun.txt"))" \
      grep -qE 'crun version 1\.(2[6-9]|[3-9][0-9])' "$OUTDIR/crun.txt"
check "crun built with +CRIU" grep -q '+CRIU' "$OUTDIR/crun.txt"

step "2/5  CRIU options"
cp /etc/criu/default.conf "$OUTDIR/criu-default.conf" 2>/dev/null || true
check "tcp-close in /etc/criu/default.conf" grep -q 'tcp-close' /etc/criu/default.conf
[ -f /etc/criu/default.conf ] && info "current: $(tr '\n' ' ' < /etc/criu/default.conf)"

step "3/5  v1.0 leftovers"
HOOK=/usr/local/lib/gpu-cr-restore/oci-hooks/gpu-cr-restore.json
if [ -f "$HOOK" ]; then
  warn "v1.0 poststart hook IS installed: $HOOK"
  if systemctl is-active --quiet gpu-cr-cuda-helper.service 2>/dev/null; then
    info "gpu-cr-cuda-helper.service is ACTIVE"
    info "  -> hook step (5) succeeds, so step (6) data.blob remap DOES run"
    info "  -> obsolete under CRIUgpu but currently harmless"
  else
    fail "gpu-cr-cuda-helper.service is NOT active, but the hook still calls it first"
    warn "  -> step (5) times out after 120s and RETURNS EARLY"
    warn "  -> step (6), the data.blob remap, is SKIPPED"
    warn "  -> pods come up healthy with STALE GPU memory. t0-checksum will catch this."
  fi
else
  ok "no v1.0 poststart hook installed"
fi
crio config 2>/dev/null | grep -A6 hooks_dir > "$OUTDIR/hooks_dir.txt" || true
ls -l /etc/crio/crio.conf.d/ > "$OUTDIR/crio-dropins.txt" 2>&1 || true

step "4/5  CDI"
{ nvidia-ctk cdi list 2>&1 || echo "(nvidia-ctk unavailable)"; ls /etc/cdi/ /var/run/cdi/ 2>&1; } \
  > "$OUTDIR/cdi.txt"
if grep -qE 'nvidia\.com/gpu=' "$OUTDIR/cdi.txt"; then
  info "CDI IS in use -> the checkpoint_utils.go guard is a no-op here"
else
  info "CDI NOT in use -> the guard is LOAD-BEARING:"
  info "  /dev/nvidia* comes from the checkpoint's dumpSpec, nothing else supplies it"
fi

step "5/5  CRI-O"
crio config 2>/dev/null > "$OUTDIR/crio-config.txt" || true
check "enable_criu_support = true" grep -qE 'enable_criu_support[[:space:]]*=[[:space:]]*true' "$OUTDIR/crio-config.txt"
check "crio service active" systemctl is-active --quiet crio
ls -l /usr/local/libexec/crio/ > "$OUTDIR/libexec-crio.txt" 2>&1 || true
check "criu-device-restorer.sh installed" test -e /usr/local/libexec/crio/criu-device-restorer.sh

finish
