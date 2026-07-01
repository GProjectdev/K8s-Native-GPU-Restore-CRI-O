# Usage — GPU Restore (Custom CRI-O)

Covers (A) fresh install and (B) applying to a node where CRI-O is already
running. Korean (authoritative): `docs/USAGE.ko.md`.

## 0. Match the CRI-O version (required)
Build the patch against the EXACT CRI-O version your nodes run, or kubelet<->CRI-O
compatibility breaks.
```bash
crio --version        # e.g. 1.33.4  -> CRIO_VERSION=v1.33.4
```
The checkpoint system is verified on K8s/CRI-O v1.33, so build with
`CRIO_VERSION=v1.33.x` (not the patch's v1.35.0 default).

## B. Existing CRI-O node (typical)

Prerequisite (build host): Go matching cri-o's go.mod (>=1.24.3 for cri-o 1.33),
plus make/gcc/pkg-config and cri-o deps. `go: command not found` / `make Error 127`
means Go is missing:
```bash
GO_VER=go1.24.6
curl -sSfL "https://go.dev/dl/${GO_VER}.linux-amd64.tar.gz" | sudo tar -xz -C /usr/local
export PATH=$PATH:/usr/local/go/bin
sudo apt-get install -y make gcc pkg-config libseccomp-dev libgpgme-dev libbtrfs-dev libassuan-dev
```
build-crio.sh preflights this and stops with guidance if anything is missing.
```bash
# 1) build patched crio for YOUR version
CRIO_VERSION=v1.33.4 ./hack/build-crio.sh         # -> /tmp/cri-o-gpu-cr/bin/crio

# 2) back up + replace the binary on each node
CRIO_BIN="$(command -v crio)"
sudo cp -a "$CRIO_BIN" "${CRIO_BIN}.orig.$(date +%Y%m%d)"
sudo systemctl stop crio
sudo install -m0755 /tmp/cri-o-gpu-cr/bin/crio "$CRIO_BIN"

# 3) hooks + drop-in + dirs
sudo ./scripts/install-node.sh
```
No RuntimeClass needed (native restore path). Merge any existing `hooks_dir`
entries into `99-gpu-cr-restore.conf` (the drop-in overrides that key).

Verify:
```bash
crio config | grep -E 'enable_criu_support|hooks_dir'
sudo journalctl -u crio -n 50 --no-pager
kubectl get nodes
```

## Restore
Fill `deploy/sample-restore-pod-l1.yaml` (source-pod-uid, checkpoint-uri, image,
nodeSelector) and `kubectl apply -f`. Expect crio logs `gpu-cr: staged checkpoint`,
native restore, then hook `host helper restore ok` + `interceptor remap ack`.

## Rollback
```bash
sudo systemctl stop crio
sudo install -m0755 "${CRIO_BIN}.orig.YYYYMMDD" "$CRIO_BIN"
sudo rm -f /etc/crio/crio.conf.d/99-gpu-cr-restore.conf
sudo systemctl restart crio
```

## Patch rebase
If the patch doesn't apply to your version, add one line at the top of
`CreateContainer` (after the "Creating container" log, before checkpoint
detection):
```go
if err := s.stageGPUCheckpoint(ctx, req.GetConfig()); err != nil {
    return nil, fmt.Errorf("gpu-cr staging: %w", err)
}
```
and copy `crio-patch/server/gpu_cr_restore.go` into `server/`.
