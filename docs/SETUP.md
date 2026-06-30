# Experiment Guide — GPU Restore (CRI-O)

English mirror of `docs/SETUP.ko.md`. Restores a `Checkpoint.tar` (produced by the
checkpoint system) into a new Pod. Verified target: K8s v1.33 + CRI-O v1.33,
NVIDIA driver 570+, crun.

## 0. Prerequisites
- The checkpoint system is installed and a `Checkpoint.tar` exists.
- Each GPU worker has: driver 570+, `cuda-checkpoint`, CRIU, crun,
  CRI-O with `enable_criu_support`, the `gpu-cr-cuda-helper.service` host helper
  (handling `restore <pid>`), the interceptor lib at
  `/var/lib/gpu-cr/lib/libgcr-interceptor.so`, and the NVIDIA device plugin.

## 1. Install the runtime handler (each GPU worker)
```bash
git clone https://github.com/GProjectdev/K8s-Native-GPU-Restore-CRI-O.git
cd K8s-Native-GPU-Restore-CRI-O
sudo ./scripts/install-crio-runtime.sh
```

## 2. Register the RuntimeClass (once per cluster)
```bash
kubectl apply -f config/runtimeclass.yaml
```

## 3. Stage the checkpoint
Same-node restore: the tar is already in `/var/lib/gcr-checkpoint`. Cross-node
migration: move the tar to the target node, or use an `nfs://` / `https://` URI.
Get the source Pod UID (data-remap signal key):
```bash
kubectl get pod <source-pod> -o jsonpath='{.metadata.uid}'
```

## 4. Apply the restore Pod
Fill `REPLACE_WITH_SOURCE_POD_UID`, `checkpoint-uri`, and the `nodeSelector`
hostname in `deploy/sample-restore-pod-l1.yaml`, then:
```bash
kubectl apply -f deploy/sample-restore-pod-l1.yaml
kubectl get pod restore-cuda-l1 -w
```

## 5. Verify
```bash
kubectl get pod restore-cuda-l1 -o wide
sudo journalctl -u crio | grep gpu-cr-restore | tail -40
kubectl logs restore-cuda-l1 | tail -5   # checksum ... OK
```
Expect, in order: `staged checkpoint`, `CRIU restore done`,
`host helper restore ok`, `interceptor remap ack`, and a matching checksum.

## 6. Troubleshooting
See `docs/SETUP.ko.md` for the troubleshooting table.
