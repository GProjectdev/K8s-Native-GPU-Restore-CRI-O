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

### Where to run each test

`00-preflight` reads node-local files (`/usr/lib/criu`, `/etc/criu/default.conf`,
`crio config`, systemd) — run it **on the merged node**.

Every other test needs two things: `kubectl` to drive pods, and
`journalctl -u crio` **from the node under test**. On this cluster `kubectl` lives
on `jsj-master`, so:

```bash
# once, on jsj-master
ssh-copy-id root@jsj-worker-1
ssh-copy-id root@jsj-worker-2        # only needed for the cross-node tests
```

ssh is convenient but not required. `node_journal` tries three sources in order:

1. **`CRIO_LOG=<file>`** — a journal you collected yourself. No ssh at all.
2. **local `journalctl`** — when the suite runs on the target node.
3. **ssh** — key-based access to the target node.

If none work it prints the exact command to run on the node and fails the
log-based checks rather than passing them. An empty log must never read as
"the bad log line is absent" — that is what `require_journal` guards.

**Two-terminal workflow (no ssh).** Each test prints the `--since` timestamp it
will use and, when it cannot reach the node, tells you to start this on the node
before continuing:

```bash
# terminal 2, on jsj-worker-1
journalctl -u crio --since '<timestamp printed by the test>' -f | tee /tmp/crio.log
```

Ctrl-C when the test finishes, copy the file to wherever you ran the test, and
re-run just the log evaluation:

```bash
CRIO_LOG=/tmp/crio.log ./t3-isolation/run.sh
```

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

## Cluster-specific notes (jsj cluster)

**`tcp-close` is deliberately absent from `/etc/criu/default.conf`.** Keeping it
would close live TCP connections at dump time, which breaks restore of a
long-running inference service. The cost is that a checkpoint taken while any
TCP connection is ESTABLISHED fails with `-52 "Connected TCP socket"`;
listening-only sockets are unaffected. None of the workloads in this suite open
sockets, so it does not affect these tests.

Repo A's `quickstart/scripts/gpu-worker-setup.sh` writes `tcp-close` into that
file. Re-running quickstart, or rebuilding a node from it, silently reintroduces
it — check the file afterwards.

**Preflight result 2026-08-10 (jsj-worker-1):** 7 passed, 1 informational
(`tcp-close`, above). CRIUgpu toolchain confirmed — `cuda_plugin.so`,
CRIU 4.2.1, crun 1.26 `+CRIU`, `criu-device-restorer.sh` installed,
`enable_criu_support = true`.

The leftover v1.0 poststart hook is installed *and* `gpu-cr-cuda-helper.service`
is active, so its step (5) succeeds and step (6) — the `data.blob` remap — does
run. The silent-stale-GPU-memory failure mode is therefore **not** in play, and
earlier restore results stand. The hook is redundant under CRIUgpu but harmless;
removing it is cleanup, not a fix.

**CDI: settled 2026-08-10.** The `checkpoint_utils.go` guard is load-bearing on
this cluster, not a no-op. `checkpoint_utils.go` was created upstream by commit
`4065448 "Integrate with HAMi device plugin and HAMi DRA"`, and its unconditional
`/dev/nvidia*` skip is correct under HAMi + DRA, where CDI injects the devices.
This cluster has no HAMi, runs `nvcr.io/nvidia/k8s-device-plugin:v0.16.2` with no
`DEVICE_LIST_STRATEGY` set (so the default `envvar` strategy), and no CDI wiring
on the plugin — the CRI request therefore carries no CDI devices. Without the
guard, the devices recorded in the checkpoint's `dumpSpec` are discarded and
nothing supplies `/dev/nvidia*` to the restored container. HAMi is not planned,
so this divergence from upstream is permanent.

**t3-isolation: PASSED 2026-08-10 (jsj-worker-1).** The CRI-O journal shows the
full container lifecycle for `t3-plain-gpu` — `Creating container` at
04:44:54.120, `Created container` at 04:44:54.344, `Started container` at
04:44:54.353 — with no `gpu-cr:` line anywhere between them, and no
`Assuming it is a checkpoint archive`. Because the window demonstrably contains
the container's own activity, the absence of the staging lines is evidence, not
an empty log: `stageGPUCheckpoint`'s annotation gate returns before doing
anything for a pod that carries no `gpu-cr.io/restore`. This is the measured
basis for the Mode Isolation claim.

**t0-checksum: PASSED 2026-08-10 (jsj-worker-1).** A 512 MiB deterministic GPU
tensor came back byte-identical across checkpoint and restore:
`2b51062eef45e93b7571a47a0196b8f3fcabc7644e8c06516197794e42b8856b` before and
after. This is the first evidence that the system-level path restores the
*value*, not merely that the container reaches Running.

The restored pod's log is the real artifact:

```
[gcr] interceptor loaded (pid=1) ... [VMM hooks active]
[gcr][vmm-alloc] x4   req=536870912
READY gpu_alloc bytes=536870912
CHECKSUM 2b51062e...
[gcr] checkpoint signal received
[gcr][engine] freeze: 4 segs, 2147483648 bytes -> external blob
              (unmapped before checkpoint; excluded from CRIU tar); physical released (VA kept)
[gcr] restore signal received
[gcr][engine] remap: 4 segs restored from external blob to same VA + H2D; 0 failed
CHECKSUM 2b51062e...
```

Two things to read from it. First, CRI-O restores the container's log along with
the process, so the pre-checkpoint lines are expected to be present — their being
there is not evidence of a re-run. What rules a re-run out is that
`interceptor loaded` and the four `vmm-alloc` lines appear exactly **once**: one
continuous process lifetime, not two. Second, `remap: 4 segs restored ... to same
VA + H2D; 0 failed` is the design's central claim measured directly — the virtual
addresses were never released, so the buffers land back where the process still
expects them. 4 x 512 MiB matches PyTorch's caching allocator holding the
`arange`/`sin`/`cos`/result blocks.

The remap ACK is emitted by the in-Pod interceptor, so it appears in the pod log,
not the CRI-O journal — an earlier version of this suite looked for it in the
journal and warned spuriously.

Caveat for a future round: the tensor is deterministic (`sin`/`cos` of an index
range), so in principle a re-run would recompute the same digest. The log shape
rules that out here, but seeding the tensor with something unreproducible (the
pod UID, or an unseeded `randn`) would close the hole by construction.
