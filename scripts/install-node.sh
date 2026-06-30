#!/usr/bin/env bash
# Install the GPU-restore node-side bits for the Custom CRI-O:
#   - the OCI poststart hook + its shell libs
#   - the CRI-O drop-in (enable_criu_support + hooks_dir)
#   - the staging / state directories
# Build & install the patched `crio` binary first (hack/build-crio.sh).
set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "run as root"; exit 1; }
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="/usr/local/lib/gpu-cr-restore"

echo "[node] installing hooks + libs -> ${DEST}"
mkdir -p "${DEST}/hooks" "${DEST}/oci-hooks"
cp -rf "${REPO_DIR}/hooks/." "${DEST}/hooks/"
chmod +x "${DEST}/hooks/gpu-cr-restore-hook"
cp -f "${REPO_DIR}/oci-hooks/gpu-cr-restore.json" "${DEST}/oci-hooks/"

echo "[node] installing CRI-O drop-in"
mkdir -p /etc/crio/crio.conf.d
cp -f "${REPO_DIR}/config/crio/99-gpu-cr-restore.conf" /etc/crio/crio.conf.d/

mkdir -p /var/lib/gpu-cr/restore /var/lib/gpu-cr/run /var/lib/gpu-cr/cuda-req /var/lib/gcr-checkpoint

echo "[node] validating + restarting crio"
crio config >/dev/null 2>&1 || echo "[node] WARN: 'crio config' non-zero; check the drop-in"
systemctl restart crio
sleep 2 && systemctl is-active crio && echo "[node] crio active"
echo "[node] ensure gpu-cr-cuda-helper.service (checkpoint repo) runs here for step 5"
