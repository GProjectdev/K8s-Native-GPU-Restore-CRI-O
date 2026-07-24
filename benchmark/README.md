# Restore benchmark — gcr vs baseline

`restore-bench.sh` measures **GPU restore time** on the Custom CRI-O path and
compares **OUR system (gcr)** against **baseline (pure CRIUgpu)** — the restore-side
counterpart to the checkpoint repo's `benchmark/run.sh`.

| Mode | Checkpoint artifact | How it restores |
|---|---|---|
| **gcr** | `.tar` (CPU + GPU **control** state) + external `.blob` (GPU **data**) | CRIU restores CPU + control state; the in-Pod interceptor then re-maps the GPU data from the `.blob` to the same VA |
| **baseline** | one `.tar` with the **whole GPU** inside | CRIU + cuda_plugin restore CPU + the entire GPU; no interceptor, no blob remap |

### Phases measured (per run)

| Column | Meaning | Source |
|---|---|---|
| `stage_s` | Custom CRI-O fetches the archive(s) onto the node | CRI-O journal |
| `criu_s` | CRIU restore (`restore.log` last ts). **baseline: includes ALL GPU data** | `restore.log` |
| `cuda_plugin_s` | cuda_plugin span within `criu_s` | `restore.log` |
| `remap_s` | interceptor `.blob` → GPU data remap (**gcr only**) | restore-agent journal |
| `total_s` | apply → Pod Running (CRIU restore visible) | this script |
| `usable_s` | apply → app fully usable — **gcr**: until remap done; **baseline**: `= total_s` | agent journal / this script |

The headline number is **`usable_s`** (time until the workload can actually run on the
GPU) and the printed delta `baseline_usable − gcr_usable` (positive = gcr faster).

## What YOU must set up first

1. **Two checkpoints of the SAME workload**, one per mode — produce them with the
   *checkpoint* repo's `benchmark/run.sh` (or its agent) in each mode:
   - **gcr**: agent `GCR_INTERCEPTION=true` → stores `<name>.tar` **and** `<name>.blob`.
   - **baseline**: agent `GCR_INTERCEPTION=false` → stores a single `<name>.tar` (GPU data inside).
   Use a **socket-clean, offline** workload so both restore without the `--tcp-close`
   failure (see `docs/SETUP.ko.md` §7).

2. **Two restore manifests** — generate one per checkpoint (reuse each run):
   ```bash
   ./scripts/gen-restore-pod.sh /mnt/nfs/gcr/<gcr-ckpt>.tar \
     --name restore-gcr  --uid <src-uid> --node <target> --image <img> \
     --uri "nfs://<server>/<path>/<gcr-ckpt>.tar"  > deploy/restore-gcr.yaml

   ./scripts/gen-restore-pod.sh /mnt/nfs/gcr/<baseline-ckpt>.tar \
     --name restore-base --uid <src-uid> --node <target> --image <img> \
     --uri "nfs://<server>/<path>/<baseline-ckpt>.tar" > deploy/restore-baseline.yaml
   ```
   > The baseline manifest still uses the gpu-cr staging annotations (to fetch the tar);
   > it just has no `.blob`/interceptor, so the restore-agent's remap is a no-op there —
   > harmless, and the benchmark deletes the pod right after measuring.

3. **Pre-pull the image** on the target node (`sudo crictl pull <img>`) so image-pull
   time doesn't skew `total_s` (manifests use `imagePullPolicy: IfNotPresent`).

4. **Free GPU** on the target node (single-GPU: nothing else may hold it).

5. **Host access** for the phase split (CRI-O/agent journals, `restore.log`, staged
   files live on the target node): run on the master with `NODE_SSH="ssh <target>"`
   (root-capable SSH), or run on the node itself with `NODE_SSH=""`. Without it you
   still get `total_s`/`usable_s`; per-phase columns stay blank.

## Run

```bash
GCR_YAML=deploy/restore-gcr.yaml \
BASE_YAML=deploy/restore-baseline.yaml \
NODE_SSH="ssh jsj-worker-2" \
RUNS=5 \
./benchmark/restore-bench.sh
```

Single-mode (gcr only) also works: `RESTORE_YAML=deploy/restore-gcr.yaml ./benchmark/restore-bench.sh`.

Output: `restore-bench.csv` + a comparison summary:

```
[bench] MEDIAN per mode:
  mode         total   usable    stage     criu  cuda_pl    remap   n
  baseline      6.10     6.10     2.10     3.80     3.10        -    5
  gcr           4.90     5.70     2.40     1.35     0.60     0.80    5

[bench] gcr vs baseline (positive = gcr faster):
  time-to-usable:  gcr 5.70s  baseline 6.10s  -> +0.40 s
  time-to-Running: gcr 4.90s  baseline 6.10s  -> +1.20 s
```

## Env knobs

| Var | Default | Meaning |
|---|---|---|
| `GCR_YAML` / `BASE_YAML` | — | the two restore manifests (give one or both) |
| `RESTORE_YAML` | — | alias for `GCR_YAML` (single-mode, back-compat) |
| `NODE_SSH` | `""` (local) | host cmd access to the target node |
| `RUNS` | `5` | repeats per mode (median reported) |
| `TIMEOUT` | `600` | per-run seconds to reach Running |
| `REMAP_TIMEOUT` | `120` | gcr: max wait for the interceptor remap to finish |
| `OUT` | `restore-bench.csv` | results CSV |
| `CRIO_UNIT` / `AGENT_UNIT` | `crio` / `gpu-cr-restore-agent` | systemd units |
| `DATA_DIR` / `STAGE_DIR` | `/var/lib/gcr-data` / `/var/lib/gpu-cr/restore` | blob / staged-tar dirs |
| `KEEP_LAST` | `0` | `1` = leave the last restored pod running |

## Caveats

- Phase timestamps come from journald receive time; sub-100 ms splits are approximate.
- `restore.log` is readable only for **successful** restores, so `criu_s`/`cuda_plugin_s`
  are blank on failed runs.
- Fair comparison requires the **same workload/model** checkpointed in both modes, the
  same target node, and a pre-pulled image.

## Bulk generate + verify (restore-check.sh)

If you already have many checkpoints (e.g. from the checkpoint bench), you don't have
to hand-write a manifest each time. `restore-check.sh` takes your checkpoint **list**
(the `ls`/status table — it only needs the **source-pod-uid** and the **`.tar` path**
per line), generates a restore manifest for each, and — with `CHECK=1` — restores each
one and reports **PASS/FAIL**, dumping the error (pod events + CRIU `restore.log` tail +
CRI-O journal) when it fails.

Why it needs the node/NFS: `gen-restore-pod.sh` **reads each checkpoint tar** to pull
the exact NVIDIA driver bind-mounts the original pod used (they live in the tar's
`spec.dump`, paths vary per driver), so the tars must be readable and the driver
sources present — i.e. the GPU node with the NFS mounted. The status table alone is
not enough.

Two ways to run:

```bash
# A) ON the target node (NFS mounted there, kubectl works there):
SERVER=<nfs-ip> NODE=jsj-worker-2 CHECK=1 CKPTS_FILE=ckpts.txt ./benchmark/restore-check.sh

# B) From the MASTER: SSH to the node for the tar-read + gen, kubectl runs locally:
SERVER=<nfs-ip> NODE=jsj-worker-2 NODE_SSH="ssh jsj-worker-2" \
  CHECK=1 CKPTS_FILE=ckpts.txt ./benchmark/restore-check.sh
```

`SERVER` is the NFS server IP baked into the `nfs://` checkpoint-uri (must be mountable
from the target node at restore time). `ckpts.txt` = your status table (a header line
without a UUID is skipped automatically).

Output (one row per checkpoint):

```
manifest                                   mode      check  time_s   note
r-b-gcr-pytorch-gpt2-r1                     gcr       PASS   6.2      Running
r-b-baseline-pytorch-facebook-opt-1-3b-r1  baseline  FAIL   9.8      phase=? -> see dump below
  ----- FAIL dump: r-b-baseline-... -----
    ... pod events ...
    -- CRIU restore.log tail --
    ... Error (criu/...): ...
```

- `mode` is inferred from the name (`-gcr-` → gcr, else baseline).
- Manifests are written to `OUTDIR` (default `deploy/bench/`). The **PASS** ones can be
  fed straight into `restore-bench.sh` (`GCR_YAML=deploy/bench/<gcr>.yaml
  BASE_YAML=deploy/bench/<baseline>.yaml`).
- `CHECK=0` only generates the manifests (apply them from the master yourself).

Env: `SERVER` (NFS IP, required), `NODE`, `IMAGE`, `OUTDIR`, `CHECK`, `TIMEOUT`,
`KUBECTL`, `NS`.
