# Restore Orchestrator — WorkloadRestore / GPURestore + Mutating Webhook

Higher-level, CR-driven restore control plane for the K8s-Native GPU restore
system. It mirrors the checkpoint side's `WorkloadCheckpoint → GPUCheckpoint`
fan-out with a symmetric `WorkloadRestore → GPURestore` fan-out, plus a mutating
webhook that injects the `gpu-cr.io/*` annotations the Custom CRI-O + Restore Agent
already consume. The existing per-node data plane (CRI-O patch, restore-agent,
hooks) is untouched.

## Why this is compatible with the current checkpoint method

The current checkpoint method (CRIUgpu control + GCR interceptor blob, orchestrated
by `WorkloadCheckpoint`) records, **per replica**, in `WorkloadCheckpoint.status.targets[]`:
`podName`, `node`, and `path` (the stored `Checkpoint.tar`). The GPU data blob is
the sibling of the tar (`.tar → .blob`). So a restore controller can read those
records and produce, for each replica, exactly what Custom CRI-O needs:
`gpu-cr.io/checkpoint-uri` (from `path`) and `gpu-cr.io/data-uri` (derived). **Yes,
it works with the current checkpoint output.**

**One integration point — the source Pod UID.** The blob is keyed by the ORIGINAL
Pod UID (`/var/lib/gcr-data/<uid>/data.blob`), and the restored interceptor re-opens
it under that same UID. The checkpoint CR status does **not** yet expose the source
Pod UID, so `GPURestore.spec.checkpointInfo.podUid` must be supplied one of two ways:
1. **(recommended)** add a `podUID` field to the checkpoint side's `TargetStatus`
   (the Node Agent already knows it) — the controller reads it automatically; or
2. recover it from the tar metadata (`io.kubernetes.pod.uid`, as
   `benchmark/checkpoint-info.sh` does) and set it on the `GPURestore`.
Until (1) lands, set `podUid` on the `GPURestore`/sample, or leave it empty for
same-node restores where the blob is already present under the right UID.

## Components (maps to the design slides)

- **WorkloadRestore** CR — restore trigger for a higher-level workload
  (`spec.targetWorkloadRef`, `spec.checkpointRef`). — *Slide: WorkloadRestore CR*
- **WorkloadRestore controller** — reads the referenced `WorkloadCheckpoint`'s
  `status.targets[]` and creates one **GPURestore** child per replica. — *Slide:
  WorkloadRestore Controller*
- **GPURestore** CR — one replica's checkpoint (`checkpointInfo{podUid, checkpointUri}`)
  + `workloadRestoreRef`. — *Slide: GPURestore CR*
- **Mutating webhook** (`/mutate-v1-pod`) — for each newly created Pod of the target
  workload, binds an unconsumed GPURestore and injects `gpu-cr.io/restore`,
  `checkpoint-uri`, `source-pod-uid`, `data-uri`, `blob-mode`. — *Slide: Mutation
  Webhook*
- **Custom CRI-O + Restore Agent** — unchanged; stage the archive and coordinate
  the GPU control-state restore + data-buffer remap.

## Build & deploy

```bash
make build                 # go build ./... (needs Go 1.22+)
make generate manifests    # refresh deepcopy + CRD yaml (controller-gen)
make docker-build docker-push IMG=<registry>/gpu-cr-restore-orchestrator:tag

kubectl apply -f config/crd/            # CRDs
# cert-manager required for the webhook TLS (or provide your own certs)
kubectl apply -f deploy/orchestrator-restore.yaml
kubectl apply -f deploy/sample-workloadrestore.yaml
```

> This module is intentionally separate from the CRI-O patch (which is compiled
> into cri-o). Nothing here changes the data plane; it only produces annotations.
