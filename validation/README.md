# Validation suite — merged CRI-O (GCR + FluidCR)

Tests for the CRI-O fork that carries both restore paths: GCR/CRIUgpu
(system level) and FluidCR (application level).

Scope note — this suite only exercises repositories under `GProjectdev`.
The merged binary is built from a fork of `lehuannhatrang/leehun-cri-o`; nothing
here modifies or pushes to that repository.

## Why these tests exist

Each one closes a specific gap between what the progress report claims and what
has actually been measured.

| Test | Claim it substantiates | Status before this suite |
|---|---|---|
| `00-preflight` | the node is really running CRIUgpu | partly checked by hand |
| `t3-isolation` | Mode Isolation — normal workloads unaffected | never run |
| `t0-checksum` | restore is *correct*, not just successful | never run |
| `t1-fluidcr-regression` | Mode Isolation — FluidCR path survived the merge | never run |
| `t4-dispatch` | Engineering Integration — both paths coexist | system side only |
| `t2-crossnode-system` | staging does what it exists for | **likely never run** — every sample used node-local `hostpath://` |
| `t5-crossnode-app` | Functional Extension — FluidCR gains cross-node restore | never run; the code change behind it has not been reviewed either |

## Order

Dependencies matter. Run top to bottom.

```
00-preflight          # no cluster changes; do this first
t3-isolation          # cheapest smoke test
t0-checksum           # produces the artifacts + baseline checksum for t2/t4
t1-fluidcr-regression # run TWICE: merged node, then pre-merge control node
t4-dispatch           # needs t0 + t1 artifacts
t2-crossnode-system   # needs t0 artifacts on the shared mount
t5-crossnode-app      # needs the FluidCR payload on the shared mount
```

## Before anything

Two things are worth settling first, because they change what the results mean.

**1. Read the four unreviewed changes.** `t5` in particular is written against an
assumption about how `app-payload-uri` staging works.

```bash
git -C ~/gpu-cr-merge/base-crio diff HEAD
```

**2. Decide what to do about the `v1.0` poststart hook.** With CRIUgpu the host
`cuda-checkpoint` helper is obsolete, but the hook still calls it *first* and
returns early if it fails:

```bash
gcr_cuda_helper_restore "$pid" || return 1   # (5) obsolete under CRIUgpu
gcr_signal_interceptor  "$srcuid"            # (6) data.blob remap — still required
```

If `gpu-cr-cuda-helper.service` is not running, step (5) times out after 120 s,
the function returns, and step (6) never executes. The pod comes up looking
healthy with stale GPU memory. `00-preflight` flags this and `t0-checksum` is
what would actually catch it.

## Configuration

Everything is env-driven; defaults live at the top of `lib/common.sh`.

| Variable | Default | Meaning |
|---|---|---|
| `MERGED_NODE` | `jsj-worker-1` | node running the merged CRI-O |
| `CONTROL_NODE` | `jsj-worker-2` | node kept on the pre-merge binary (A/B control) |
| `NFS_ENDPOINT` / `NFS_PATH` | `10.178.0.14` `/mnt/nfs` | shared storage for cross-node staging |
| `NS` | `default` | namespace |
| `TIMEOUT` | `300` | per-wait timeout, seconds |

Tests that touch FluidCR need these; there are no sensible defaults, so they
fail fast if unset:

| Variable | Meaning |
|---|---|
| `FLUIDCR_IMAGE` | the FluidCR-enabled training image |
| `FLUIDCR_CHECKPOINT_PATH` | local checkpoint path for FluidCR's native restore |
| `APP_PAYLOAD` | FluidCR payload name on the share (`t5`) |

`t1-fluidcr-regression/00-source-pod.yaml` is deliberately a skeleton — copy the
volume mounts and env from the FluidCR pod that worked before the merge. A
regression test is only meaningful if the pod is otherwise identical.

## Running

```bash
export MERGED_NODE=jsj-worker-1 CONTROL_NODE=jsj-worker-2
export NFS_ENDPOINT=10.178.0.14 NFS_PATH=/mnt/nfs

sudo ./00-preflight/run.sh
./t3-isolation/run.sh
./t0-checksum/run.sh

# A/B — the two result dirs should agree
TARGET_NODE=$CONTROL_NODE FLUIDCR_IMAGE=... FLUIDCR_CHECKPOINT_PATH=... ./t1-fluidcr-regression/run.sh
TARGET_NODE=$MERGED_NODE  FLUIDCR_IMAGE=... FLUIDCR_CHECKPOINT_PATH=... ./t1-fluidcr-regression/run.sh
diff -r results/*-t1-fluidcr-jsj-worker-2 results/*-t1-fluidcr-jsj-worker-1

export SOURCE_POD_UID=$(cat results/*-t0-checksum/…)   # printed by t0
export CHECKSUM_BEFORE=$(cat results/*-t0-checksum/checksum.before)
./t4-dispatch/run.sh
./t2-crossnode-system/run.sh
APP_PAYLOAD=appckpt-1 ./t5-crossnode-app/run.sh
```

Scripts run on the merged node, or anywhere with `kubectl` plus passwordless
`ssh` to the nodes (`node_journal` needs it to pull `journalctl -u crio`).

Everything lands under `validation/results/<timestamp>-<test>/`: rendered
manifests, pod logs, CRI-O journal slices, checksums. `results/` is gitignored —
copy out what you want to keep as evidence.

## Reading the output

`[ PASS ]` / `[ FAIL ]` per check, count at the end. Two artifacts are worth
keeping for the report:

- `t4-dispatch/…/dispatch.log` — the annotation→entry-point mapping, straight
  from the runtime. This is the figure for the dispatch slide.
- `t0-checksum/…/checksum.{before,after}` — turns "restore succeeded" into
  "restore preserved the tensor".

## What this suite does not cover

- Multi-GPU and multi-process (NCCL) workloads — single container, single GPU only
- The CR / controller / webhook layer, which is still design-only
- Checkpoint-side performance (repo A's `benchmark/` covers that)
