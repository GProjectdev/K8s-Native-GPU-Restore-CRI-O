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
                                                # (applies cleanly to cri-o v1.35.0)
oci-hooks/gpu-cr-restore.json + hooks/          # poststart hook: GPU control-state
                                                # restore + data-buffer remap
```

## Restore flow

```
1  apply Restore Pod yaml   (image = checkpoint archive path)
2  scheduler picks node     (experiment: nodeSelector)
2.5 Custom CRI-O STAGES the tar from gpu-cr.io/checkpoint-uri onto the node
3  kubelet -> CRI-O detects the local archive
4  CRIU restore             (container + CPU process)
5  poststart hook: GPU control state  (cuda-checkpoint --restore via host helper)
6  poststart hook: GPU data buffers   (interceptor remap to SAME VA + H2D)
7  workload resumes
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
./hack/build-crio.sh                                   # build patched cri-o v1.35.0
sudo install -m0755 /tmp/cri-o-gpu-cr/bin/crio "$(command -v crio)"   # per node
sudo ./scripts/install-node.sh                         # hooks + config + dirs
kubectl apply -f deploy/sample-restore-pod-l1.yaml     # fill placeholders first
```

Full steps: [docs/SETUP.ko.md](docs/SETUP.ko.md).

## Status

Experimental, single-container / single-GPU. **Verified end-to-end on cri-o
v1.33.13 (K8s v1.33, NVIDIA driver 570.211.01, A100):** same-node restore and
cross-node migration (worker-1 → worker-2, checkpoint pulled over HTTP) both
resume the workload with a bit-exact GPU checksum, fully automatic via the
restore-agent (just `kubectl apply`). The patch set (0001–0004) applies cleanly to
cri-o v1.35.0 and v1.33.13. Assumptions and remaining points are in
[docs/DESIGN.ko.md](docs/DESIGN.ko.md); cross-node steps in
[docs/MIGRATION.ko.md](docs/MIGRATION.ko.md).
