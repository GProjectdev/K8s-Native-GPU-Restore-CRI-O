#!/usr/bin/env bash
# Remove everything the suite creates. Safe to run at any time.
. "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"
info "removing suite pods and CRs in namespace $NS"
kubectl -n "$NS" delete pod \
  t3-plain-gpu \
  t0-cuda-checksum t0-restore \
  t1a-native-src t1a-native-restore \
  t1b-fluidcr-src t1b-fluidcr-restore \
  t2-restore-crossnode \
  --ignore-not-found --wait=false 2>/dev/null || true
kubectl -n "$NS" delete gpucheckpoint.gpu-cr.io t0-ckpt --ignore-not-found 2>/dev/null || true
echo
kubectl -n "$NS" get pods 2>/dev/null | grep -E '^(t0|t1a|t1b|t2|t3)-' && \
  warn "some are still terminating — rerun in a few seconds" || \
  ok "no suite pods left"
