#!/usr/bin/env bash
# Generate a restore Pod manifest with the EXACT external bind mounts a checkpoint
# expects, using their real host sources from the checkpoint's spec.dump.
#
# Why: CRI-O restore requires every non-standard bind mount recorded in the
# checkpoint (the NVIDIA driver libs/binaries/configs injected by
# nvidia-container-runtime) to be present in the new Pod's mounts. Some of these
# have source != destination (e.g. a vulkan/EGL json mounted from another host
# path), so a naive "hostPath at the same path" fails at runtime with
# "bind mount source ... is missing". spec.dump has the correct source per mount.
#
# Run this ON THE NODE that holds the checkpoint tar (sources must exist there).
#
# Usage:
#   scripts/gen-restore-pod.sh <checkpoint.tar> \
#       --name restore-cuda-l1 --uid <source-pod-uid> --node <hostname> \
#       [--namespace default] [--image pytorch/pytorch:2.4.0-cuda12.1-cudnn9-runtime] \
#       [--gpus 1] > restore.yaml
set -euo pipefail
TAR=""; NAME="restore-pod"; UID_SRC=""; NODE=""; NS="default"
IMG="pytorch/pytorch:2.4.0-cuda12.1-cudnn9-runtime"; GPUS="1"; CTR="cuda-app"
URI=""
while [ $# -gt 0 ]; do
  case "$1" in
    --name) NAME="$2"; shift 2;;
    --uid) UID_SRC="$2"; shift 2;;
    --node) NODE="$2"; shift 2;;
    --namespace) NS="$2"; shift 2;;
    --image) IMG="$2"; shift 2;;
    --gpus) GPUS="$2"; shift 2;;
    --container) CTR="$2"; shift 2;;
    --uri) URI="$2"; shift 2;;
    -*) echo "unknown flag $1" >&2; exit 1;;
    *) TAR="$1"; shift;;
  esac
done
[ -n "$TAR" ] && [ -f "$TAR" ] || { echo "usage: $0 <checkpoint.tar> --uid <uid> --node <node> [...]" >&2; exit 1; }
[ -z "$URI" ] && URI="hostpath://$(readlink -f "$TAR")"

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
# spec.dump lives at the root of a kubelet/CRI-O checkpoint tar.
tar -xf "$TAR" -C "$WORK" spec.dump 2>/dev/null || tar -xf "$TAR" -C "$WORK" ./spec.dump
SPEC="$WORK/spec.dump"
[ -f "$SPEC" ] || { echo "spec.dump not found in $TAR" >&2; exit 1; }

NAME="$NAME" UID_SRC="$UID_SRC" NODE="$NODE" NS="$NS" IMG="$IMG" GPUS="$GPUS" CTR="$CTR" URI="$URI" \
python3 - "$SPEC" <<'PY'
import json,os,sys
spec=json.load(open(sys.argv[1]))
env=os.environ
# Destinations CRI-O/k8s provide automatically or we already declare — skip these.
skip_prefixes=("/proc","/sys","/dev","/etc/hostname","/etc/hosts","/etc/resolv.conf",
               "/run/secrets/kubernetes.io","/var/run/secrets/kubernetes.io",
               "/opt/gpu-cr","/var/lib/gpu-cr","/var/lib/gcr-checkpoint","/etc/hostname")
def skip(dst):
    return any(dst==p or dst.startswith(p+"/") or dst.startswith(p) for p in skip_prefixes)
binds=[]
for m in spec.get("mounts",[]):
    dst=m.get("destination",""); src=m.get("source",""); typ=m.get("type","")
    if not dst or not src: continue
    if typ not in ("bind","none") and "bind" not in m.get("options",[]): 
        # keep only real bind mounts (nvidia files are binds)
        if typ!="bind": continue
    if skip(dst): continue
    if not os.path.exists(src):
        print(f"# WARNING: source missing on this node, skipping: {src} -> {dst}", file=sys.stderr)
        continue
    binds.append((src,dst))

vm=[]; vol=[]
for i,(src,dst) in enumerate(binds):
    n=f"nv{i}"
    vm.append(f"        - {{ name: {n}, mountPath: {dst}, readOnly: true }}")
    vol.append(f"    - {{ name: {n}, hostPath: {{ path: {src} }} }}")

print(f"""apiVersion: v1
kind: Pod
metadata:
  name: {env['NAME']}
  namespace: {env['NS']}
  annotations:
    gpu-cr.io/restore: "true"
    gpu-cr.io/checkpoint-uri: "{env['URI']}"
    gpu-cr.io/source-pod-uid: "{env['UID_SRC']}"
spec:
  nodeSelector:
    kubernetes.io/hostname: {env['NODE']}
  restartPolicy: Never
  containers:
    - name: {env['CTR']}
      image: {env['IMG']}
      imagePullPolicy: IfNotPresent
      resources:
        limits:
          nvidia.com/gpu: "{env['GPUS']}"
      volumeMounts:
        - {{ name: gpu-cr-lib, mountPath: /opt/gpu-cr, readOnly: true }}
        - {{ name: gpu-cr-run, mountPath: /var/lib/gpu-cr/run }}
        - {{ name: gcr-checkpoint, mountPath: /var/lib/gcr-checkpoint }}
        # --- external bind mounts from the checkpoint spec.dump ({len(binds)}) ---""")
print("\n".join(vm))
print("""  volumes:
    - { name: gpu-cr-lib, hostPath: { path: /var/lib/gpu-cr/lib, type: Directory } }
    - { name: gpu-cr-run, hostPath: { path: /var/lib/gpu-cr/run, type: DirectoryOrCreate } }
    - { name: gcr-checkpoint, hostPath: { path: /var/lib/gcr-checkpoint, type: DirectoryOrCreate } }""")
print("\n".join(vol))
PY
