#!/usr/bin/env bash
# Install the gpu-cr-restore CRI-O runtime handler on THIS node.
#   - installs the shim + lib under /usr/local/lib/gpu-cr-restore
#   - symlinks /usr/local/bin/gpu-cr-restore-shim
#   - drops the CRI-O runtime config and restarts crio
# Run as root on each GPU worker. Apply config/runtimeclass.yaml once per cluster.
set -euo pipefail
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="/usr/local/lib/gpu-cr-restore"
CRIO_DROPIN="/etc/crio/crio.conf.d/99-gpu-cr-restore.conf"

[ "$(id -u)" -eq 0 ] || { echo "run as root"; exit 1; }

echo "[install] copying runtime to ${DEST}"
mkdir -p "${DEST}"
cp -rf "${REPO_DIR}/runtime/." "${DEST}/"
chmod +x "${DEST}/gpu-cr-restore-shim"
ln -sf "${DEST}/gpu-cr-restore-shim" /usr/local/bin/gpu-cr-restore-shim

echo "[install] crun at: $(command -v crun || echo '/usr/bin/crun (expected)')"

echo "[install] installing CRI-O drop-in ${CRIO_DROPIN}"
mkdir -p /etc/crio/crio.conf.d
cp -f "${REPO_DIR}/config/crio/99-gpu-cr-restore.conf" "${CRIO_DROPIN}"

mkdir -p /var/lib/gpu-cr/restore /var/lib/gpu-cr/run /var/lib/gpu-cr/cuda-req /var/lib/gcr-checkpoint

echo "[install] validating CRI-O config"
crio config >/dev/null 2>&1 || echo "[install] WARN: 'crio config' returned non-zero; check the drop-in"

echo "[install] restarting crio"
systemctl restart crio
sleep 2
systemctl is-active crio && echo "[install] crio active"

echo "[install] done. Next:"
echo "  kubectl apply -f ${REPO_DIR}/config/runtimeclass.yaml   # once per cluster"
echo "  ensure CRIUgpu (CRIU + cuda_plugin) is enabled on this node — see the checkpoint repo's gpu-worker-setup.sh"
