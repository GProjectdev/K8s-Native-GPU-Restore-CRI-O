#!/usr/bin/env bash
# Build the Custom CRI-O (stock CRI-O v1.35.0 + the gpu-cr restore staging patch).
#
#   - clones cri-o at the pinned tag
#   - drops in server/gpu_cr_restore.go
#   - applies crio-patch/0001-create-stage-gpu-checkpoint.patch
#   - builds the `crio` binary
#
# Requires: go (>=1.22), make, git, build deps for cri-o (libgpgme, libseccomp,
# libbtrfs headers). Run on a build host, then install bin/crio onto the nodes.
set -euo pipefail
CRIO_VERSION="${CRIO_VERSION:-v1.35.0}"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${SRC_DIR:-/tmp/cri-o-gpu-cr}"

echo "[build] cloning cri-o ${CRIO_VERSION} -> ${SRC}"
rm -rf "${SRC}"
git clone --depth 1 --branch "${CRIO_VERSION}" https://github.com/cri-o/cri-o.git "${SRC}"

echo "[build] adding server/gpu_cr_restore.go"
cp "${REPO_DIR}/crio-patch/server/gpu_cr_restore.go" "${SRC}/server/gpu_cr_restore.go"

echo "[build] applying staging patch"
git -C "${SRC}" apply "${REPO_DIR}/crio-patch/0001-create-stage-gpu-checkpoint.patch"

echo "[build] building crio"
make -C "${SRC}" binaries

echo "[build] done:"
ls -l "${SRC}/bin/crio"
echo
echo "Install onto a node:"
echo "  sudo install -m0755 ${SRC}/bin/crio \$(command -v crio)   # replace the node binary"
echo "  sudo ${REPO_DIR}/scripts/install-node.sh                  # hooks + config + dirs"
echo "  sudo systemctl restart crio"
