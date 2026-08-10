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
[ -f /etc/criu/default.conf ] && info "current: $(tr '\n' ' ' < /etc/criu/default.conf)"
# NOT a pass/fail. tcp-close is a deliberate trade-off on this cluster:
#   present -> dumps with live TCP connections succeed, but the connections are
#              CLOSED, which breaks restore of a long-lived inference service
#   absent  -> connections survive the round trip, but a dump taken while any
#              TCP connection is ESTABLISHED fails with -52 "Connected TCP socket"
# It is intentionally absent here. Listening-only sockets dump fine either way.
if grep -q 'tcp-close' /etc/criu/default.conf 2>/dev/null; then
  info "tcp-close IS set -> live TCP connections are closed at dump time"
  warn "  inference services will not survive the round trip with their connections"
else
  info "tcp-close is NOT set (intentional: keeps inference-service connections intact)"
  warn "  a checkpoint taken while a TCP connection is ESTABLISHED will fail with -52"
  warn "  repo A's quickstart/gpu-worker-setup.sh re-adds tcp-close; do not let it"
fi

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
# The checkpoint_utils.go guard turns on len(createConfig.GetCDIDevices()) > 0,
# i.e. on the CRI CreateContainerRequest field -- NOT on whether CDI specs merely
# exist on the node. Those are different questions, so report both.
{ nvidia-ctk cdi list 2>&1 || echo "(nvidia-ctk unavailable)"; ls /etc/cdi/ /var/run/cdi/ 2>&1; } \
  > "$OUTDIR/cdi-specs.txt"
if grep -qE 'nvidia\.com/gpu=' "$OUTDIR/cdi-specs.txt"; then
  info "CDI specs ARE registered on this node"
else
  info "no CDI specs registered on this node"
fi

# Decisive: which strategy the device plugin uses.
#   cdi-cri         -> CDIDevices populated  -> the guard is a NO-OP here
#   cdi-annotations -> may be empty          -> the guard is LOAD-BEARING
#   envvar/volume-mounts -> empty            -> the guard is LOAD-BEARING
kubectl -n kube-system get ds -o yaml 2>/dev/null \
  | grep -i -A3 'DEVICE_LIST_STRATEGY' > "$OUTDIR/device-list-strategy.txt" || true
if [ -s "$OUTDIR/device-list-strategy.txt" ]; then
  info "DEVICE_LIST_STRATEGY:"; sed 's/^/       /' "$OUTDIR/device-list-strategy.txt"
else
  warn "DEVICE_LIST_STRATEGY not found (kubectl unavailable here, or plugin uses defaults)"
  warn "  run on the control plane:"
  warn "    kubectl -n kube-system get ds -o yaml | grep -i -A3 DEVICE_LIST_STRATEGY"
fi
info "whether the CDI guard does anything on THIS cluster follows from the above"

step "5/5  CRI-O"
crio config 2>/dev/null > "$OUTDIR/crio-config.txt" || true
check "enable_criu_support = true" grep -qE 'enable_criu_support[[:space:]]*=[[:space:]]*true' "$OUTDIR/crio-config.txt"
check "crio service active" systemctl is-active --quiet crio
ls -l /usr/local/libexec/crio/ > "$OUTDIR/libexec-crio.txt" 2>&1 || true
check "criu-device-restorer.sh installed" test -e /usr/local/libexec/crio/criu-device-restorer.sh

finish
