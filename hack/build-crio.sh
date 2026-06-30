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
# IMPORTANT: build against the SAME CRI-O version your nodes already run.
# Detect it on a node with:  crio --version   (e.g. "1.33.4" -> CRIO_VERSION=v1.33.4)
# The patch was authored against v1.35.0; for another version it must still apply
# (the script runs `git apply` which fails loudly if the anchor moved -> rebase it).
CRIO_VERSION="${CRIO_VERSION:-v1.35.0}"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${SRC_DIR:-/tmp/cri-o-gpu-cr}"

echo "[build] cloning cri-o ${CRIO_VERSION} -> ${SRC}"
rm -rf "${SRC}"
git clone --depth 1 --branch "${CRIO_VERSION}" https://github.com/cri-o/cri-o.git "${SRC}"

echo "[build] adding server/gpu_cr_restore.go"
cp "${REPO_DIR}/crio-patch/server/gpu_cr_restore.go" "${SRC}/server/gpu_cr_restore.go"

echo "[build] applying staging patch"
if ! git -C "${SRC}" apply "${REPO_DIR}/crio-patch/0001-create-stage-gpu-checkpoint.patch"; then
  echo "[build] ERROR: patch did not apply to cri-o ${CRIO_VERSION}." >&2
  echo "[build] The CreateContainer anchor likely moved in this version." >&2
  echo "[build] Manually add this line at the top of CreateContainer (server/container_create.go)," >&2
  echo "[build] right after the 'Creating container' log line:" >&2
  echo "[build]     if err := s.stageGPUCheckpoint(ctx, req.GetConfig()); err != nil { return nil, fmt.Errorf(\"gpu-cr staging: %w\", err) }" >&2
  exit 1
fi

echo "[build] building crio"
make -C "${SRC}" binaries

echo "[build] done:"
ls -l "${SRC}/bin/crio"
echo
echo "Install onto a node:"
echo "  sudo install -m0755 ${SRC}/bin/crio \$(command -v crio)   # replace the node binary"
echo "  sudo ${REPO_DIR}/scripts/install-node.sh                  # hooks + config + dirs"
echo "  sudo systemctl restart crio"
