#!/usr/bin/env bash
# Build the Custom CRI-O (stock CRI-O + the gpu-cr restore staging patch).
#
#   - clones cri-o at the tag matching your nodes (CRIO_VERSION)
#   - drops in server/gpu_cr_restore.go
#   - applies crio-patch/0001-create-stage-gpu-checkpoint.patch
#   - builds the `crio` binary
#
# Requires: go (matching cri-o's go.mod — e.g. >=1.24 for cri-o 1.33), make, gcc,
# pkg-config, git, and cri-o build deps (libseccomp/libgpgme/libbtrfs/libassuan
# headers). Run on a build host, then install bin/crio onto the nodes.
set -euo pipefail

# --- preflight: toolchain check --------------------------------------------
# A missing/too-old Go is the usual failure ("go: command not found").
preflight() {
  local missing=0
  if ! command -v go >/dev/null 2>&1; then
    missing=1
    cat >&2 <<'MSG'
[build] ERROR: Go toolchain not found (go: command not found).
[build] CRI-O 1.33 needs Go >= 1.24.3. Install it on this build host:
[build]
[build]   GO_VER=go1.24.6
[build]   curl -sSfL "https://go.dev/dl/${GO_VER}.linux-amd64.tar.gz" | sudo tar -xz -C /usr/local
[build]   export PATH=$PATH:/usr/local/go/bin        # add to ~/.bashrc to persist
[build]   go version
MSG
  fi
  if ! command -v make >/dev/null 2>&1 || ! command -v gcc >/dev/null 2>&1 || ! command -v pkg-config >/dev/null 2>&1; then
    missing=1
    cat >&2 <<'MSG'
[build] ERROR: build tools/deps missing. On Debian/Ubuntu install:
[build]   sudo apt-get update && sudo apt-get install -y make gcc pkg-config \
[build]     libseccomp-dev libgpgme-dev libbtrfs-dev libassuan-dev
[build] On RHEL/CentOS/Fedora:
[build]   sudo dnf install -y make gcc pkgconf-pkg-config libseccomp-devel \
[build]     gpgme-devel device-mapper-devel
MSG
  fi
  [ "${missing}" -eq 0 ] || { echo "[build] fix the above, then re-run." >&2; exit 1; }
}
preflight

# IMPORTANT: build against the SAME CRI-O version your nodes already run.
# Detect it on a node with:  crio --version   (e.g. "1.33.13" -> CRIO_VERSION=v1.33.13)
# The patch was authored against v1.35.0; the script fails loudly if it does not
# apply to your version (rebase the one-line anchor then).
CRIO_VERSION="${CRIO_VERSION:-v1.33.13}"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${SRC_DIR:-/tmp/cri-o-gpu-cr}"

echo "[build] cloning cri-o ${CRIO_VERSION} -> ${SRC}"
rm -rf "${SRC}"
git clone --depth 1 --branch "${CRIO_VERSION}" https://github.com/cri-o/cri-o.git "${SRC}"

# Verify the installed Go satisfies THIS cri-o version's go.mod requirement.
REQ_GO="$(awk '/^go /{print $2; exit}' "${SRC}/go.mod")"
HAVE_GO="$(go env GOVERSION 2>/dev/null | sed 's/^go//')"
if [ -n "${REQ_GO}" ] && [ -n "${HAVE_GO}" ]; then
  if [ "$(printf '%s\n%s\n' "${REQ_GO}" "${HAVE_GO}" | sort -V | head -n1)" != "${REQ_GO}" ]; then
    echo "[build] ERROR: cri-o ${CRIO_VERSION} needs Go >= ${REQ_GO}, but 'go' is ${HAVE_GO}." >&2
    echo "[build] Install a newer Go (see the preflight hint) and re-run." >&2
    exit 1
  fi
  echo "[build] go ${HAVE_GO} satisfies cri-o requirement (>= ${REQ_GO})"
fi

echo "[build] adding server/gpu_cr_restore.go"
cp "${REPO_DIR}/crio-patch/server/gpu_cr_restore.go" "${SRC}/server/gpu_cr_restore.go"

echo "[build] applying gpu-cr patches"
for p in "${REPO_DIR}"/crio-patch/*.patch; do
  echo "[build]   apply $(basename "$p")"
  if ! git -C "${SRC}" apply "$p"; then
    echo "[build] ERROR: $(basename "$p") did not apply to cri-o ${CRIO_VERSION}." >&2
    echo "[build] The anchor likely moved in this version; rebase the patch (see docs/DESIGN.ko.md)." >&2
    exit 1
  fi
done

echo "[build] building crio"
make -C "${SRC}" binaries

echo "[build] done:"
ls -l "${SRC}/bin/crio"
echo
echo "Install onto a node:"
echo "  sudo install -m0755 ${SRC}/bin/crio \$(command -v crio)   # replace the node binary"
echo "  sudo ${REPO_DIR}/scripts/install-node.sh                  # hooks + config + dirs"
echo "  sudo systemctl restart crio"
