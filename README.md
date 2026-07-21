# K8s-Native-GPU-Restore-CRI-O

Custom CRI-O that **restores** a GPU workload from a `Checkpoint.tar` produced by
[K8s-Native-Fast-GPU-Checkpoint-Restore-System](https://github.com/GProjectdev/K8s-Native-Fast-GPU-Checkpoint-Restore-System).
It is a **minimal patch on CRI-O's native restore path** (in the spirit of the
`cri-o/cri-o` fork [`leehun-cri-o`](https://github.com/lehuannhatrang/leehun-cri-o)),
plus an OCI hook for the GPU-specific steps.

> 한국어: [README.ko.md](README.ko.md) · 사용법: [docs/USAGE.ko.md](docs/USAGE.ko.md) · 설계/비교: [docs/DESIGN.ko.md](docs/DESIGN.ko.md) · 실험: [docs/SETUP.ko.md](docs/SETUP.ko.md)

## Why a CRI-O fork (not a runtime shim)

CRI-O already restores a container natively when the container `image` resolves to
a local checkpoint archive (`CreateContainer` → "Assuming it is a checkpoint
archive" → `CRImportCheckpoint`/CRIU). That path handles conmon, the sandbox and
kubelet status correctly. So instead of a shim that hijacks `create` behind
CRI-O's back, we add the **one** thing the native path lacks for cross-node
restore — staging — and do the GPU work in a poststart hook. A fork-free shim
alternative is kept in [`alt-shim/`](alt-shim/) for environments that can't
rebuild CRI-O.

## What the patch adds

```
crio-patch/server/gpu_cr_restore.go            # stageGPUCheckpoint(): fetch the
                                                # checkpoint-uri onto the node and
                                                # point the image at the local tar
crio-patch/0001-create-stage-gpu-checkpoint.patch  # 1-line call in CreateContainer
                                                # (targets cri-o v1.33.x; build default v1.33.13)
oci-hooks/gpu-cr-restore.json + hooks/          # poststart hook + restore-agent:
                                                # GPU data-buffer remap (control
                                                # state comes back via CRIUgpu)
```

## Restore flow

```
1  apply Restore Pod yaml   (image = checkpoint archive path)
2  scheduler picks node     (experiment: nodeSelector)
2.5 Custom CRI-O STAGES two artifacts onto the node:
      - the checkpoint .tar (CPU + GPU control state)  -> container image
      - the sibling .blob (GPU memory data)            -> /var/lib/gcr-data/<uid>/data.blob
3  kubelet -> CRI-O detects the local archive
4  CRIU restore + cuda_plugin  (container + CPU process AND GPU control state — CRIUgpu)
5  restore-agent detects the restored container (gpu-cr.io/restore=true)
6  data remap: interceptor re-opens the .blob, recreates physical + SAME VA + H2D
7  gated kernel launches unblock -> workload resumes
8  CRI-O/kubelet register it as a normal Running container
```

A Pod requests a restore declaratively:

```yaml
metadata:
  annotations:
    gpu-cr.io/restore: "true"
    gpu-cr.io/checkpoint-uri: "hostpath:///var/lib/gcr-checkpoint/Checkpoint.tar"
    gpu-cr.io/source-pod-uid: "<original pod uid>"
spec:
  nodeSelector: { kubernetes.io/hostname: gpu-node-2 }
  containers:
    - name: vllm
      image: /var/lib/gpu-cr/restore/vllm-Checkpoint.tar   # staged local archive
      resources: { limits: { nvidia.com/gpu: 1 } }
```

## Quick start

```bash
./hack/build-crio.sh                                   # build patched cri-o (match node; default v1.33.13)
sudo install -m0755 /tmp/cri-o-gpu-cr/bin/crio "$(command -v crio)"   # per node
sudo ./scripts/install-node.sh                         # hooks + config + dirs
kubectl apply -f deploy/sample-restore-pod-l1.yaml     # fill placeholders first
```

Full steps: [docs/SETUP.ko.md](docs/SETUP.ko.md).

### Gotchas (learned the hard way)

- **Build the CRI-O version your node runs** (`crio --version` → `CRIO_VERSION=v1.33.x`).
  The patch anchors assume the 1.33 line; other versions may need a rebase.
- **crun >= 1.9** on every node.
- **Socket-clean checkpoints.** A workload holding a TCP socket at checkpoint fails to
  restore (`CRIU -52 / Need to set the --tcp-close options`) because CRI-O/crun does not
  pass `tcp-close` on restore. Make the workload offline (e.g. load models from a local
  path, `HF_HUB_OFFLINE=1`) and remove `tcp-close` from the source node's
  `/etc/criu/default.conf` so the checkpoint carries no socket state. See docs/SETUP.ko.md §7.
- **Model files:** load from a path mounted identically on source AND restore nodes.

## Status

Experimental, single-container / single-GPU. **Verified end-to-end on cri-o
v1.33.13 (K8s v1.33, NVIDIA driver 570.211.01, A100):** same-node restore and
cross-node migration (worker-1 → worker-2, checkpoint pulled over HTTP) both
resume the workload with a bit-exact GPU checksum, fully automatic via the
restore-agent (just `kubectl apply`). The patch set (0001–0004) applies cleanly to
cri-o v1.33.x (verified end-to-end on v1.33.13; anchors assume 1.33.x). Assumptions and remaining points are in
[docs/DESIGN.ko.md](docs/DESIGN.ko.md); cross-node steps in
[docs/MIGRATION.ko.md](docs/MIGRATION.ko.md).
