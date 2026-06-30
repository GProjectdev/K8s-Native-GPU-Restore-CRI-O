# Experiment Guide — GPU Restore (Custom CRI-O)

English summary of `docs/SETUP.ko.md`. Restores a `Checkpoint.tar` into a new Pod
via a patched CRI-O (v1.35.0) native restore path. Target: K8s v1.33+, driver 570+.

## 1. Build the Custom CRI-O (once)
```bash
git clone https://github.com/GProjectdev/K8s-Native-GPU-Restore-CRI-O.git
cd K8s-Native-GPU-Restore-CRI-O && ./hack/build-crio.sh
```

## 2. Install on each GPU worker
```bash
sudo install -m0755 /tmp/cri-o-gpu-cr/bin/crio "$(command -v crio)"
sudo ./scripts/install-node.sh
sudo systemctl restart crio
```

## 3. Stage + restore
Get the source Pod UID (`kubectl get pod <src> -o jsonpath='{.metadata.uid}'`),
fill `deploy/sample-restore-pod-l1.yaml` (source-pod-uid, checkpoint-uri, image,
nodeSelector), then `kubectl apply -f` it.

## 4. Verify
```bash
sudo journalctl -u crio | grep gpu-cr | tail
kubectl logs restore-cuda-l1 | tail -5   # checksum ... OK
```
Expect: `gpu-cr: staged checkpoint`, native CRIU restore, then the poststart hook
`host helper restore ok` + `interceptor remap ack`, and a matching checksum.

A fork-free runtime-shim alternative lives in `alt-shim/` (less robust). See
`docs/DESIGN.ko.md` for the approach comparison and honest unverified points.
