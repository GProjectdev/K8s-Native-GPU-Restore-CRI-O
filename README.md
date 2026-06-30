# K8s-Native-GPU-Restore-CRI-O

Custom CRI-O runtime handler that **restores** a GPU workload from a
`Checkpoint.tar` produced by
[K8s-Native-Fast-GPU-Checkpoint-Restore-System](https://github.com/GProjectdev/K8s-Native-Fast-GPU-Checkpoint-Restore-System)
— the exact reverse of that project's checkpoint pipeline.

> 한국어: [README.ko.md](README.ko.md) · 설계: [docs/DESIGN.ko.md](docs/DESIGN.ko.md) · 실험: [docs/SETUP.ko.md](docs/SETUP.ko.md)

## How it works

A Pod requests a restore declaratively:

```yaml
metadata:
  annotations:
    gpu-cr.io/restore: "true"
    gpu-cr.io/checkpoint-uri: "hostpath:///var/lib/gcr-checkpoint/Checkpoint.tar"
    gpu-cr.io/source-pod-uid: "<original pod uid>"
spec:
  runtimeClassName: gpu-cr-restore
  nodeSelector: { kubernetes.io/hostname: gpu-node-2 }
  containers:
    - { name: vllm, image: <ckpt-compatible>, resources: { limits: { nvidia.com/gpu: 1 } } }
```

`runtimeClassName: gpu-cr-restore` routes the container to CRI-O's
`gpu-cr-restore` handler — our shim (`runtime/gpu-cr-restore-shim`), a thin
wrapper around `crun`. It proxies every OCI verb through to `crun`, except a
restore-annotated `create`, which runs the restore pipeline:

```
1  apply Restore Pod yaml
2  scheduler picks target node      (experiment: nodeSelector)
2.5 shim STAGES Checkpoint.tar onto the node   (file/hostpath/nfs/https)
3  kubelet -> CRI-O (gpu-cr-restore handler)
4  crun restore   — CRIU restores container + CPU process
5  GPU control state — cuda-checkpoint --restore (via host helper)
6  GPU data buffers  — interceptor remap to SAME VA + H2D
7  workload resumes
8  CRI-O/kubelet register it as a normal Running container
```

CUDA was suspended at checkpoint time, so after CRIU restore the process blocks
on its next CUDA call until steps 5/6 put the device state back — a safe window.
Virtual addresses are never freed, so data buffers remap to the same VA and the
restored GPU pointers stay valid.

## Layout

```
runtime/gpu-cr-restore-shim   OCI runtime wrapper (CRI-O handler)
runtime/lib/                  common / stage / gpu-restore modules
config/crio/                  CRI-O drop-in registering the handler
config/runtimeclass.yaml      RuntimeClass gpu-cr-restore
deploy/                       sample restore Pods (annotation-driven)
scripts/install-crio-runtime.sh   per-node installer
docs/                         DESIGN.ko / SETUP.ko / SETUP
```

## Quick start

Per GPU worker: `sudo ./scripts/install-crio-runtime.sh`.
Once per cluster: `kubectl apply -f config/runtimeclass.yaml`.
Then fill and apply `deploy/sample-restore-pod-l1.yaml`. Full steps in
[docs/SETUP.ko.md](docs/SETUP.ko.md).

## Status & scope

Experimental, single-container / single-GPU reference. The shim is a Bash crun
wrapper for transparency and node-side inspectability; a compiled runtime is a
later option. Honest assumptions and unverified interaction points are listed in
[docs/DESIGN.ko.md](docs/DESIGN.ko.md) ("가능성 판단 / 미검증 지점").
