# Restore benchmark

`restore-bench.sh` measures **how long a GPU restore takes** on the Custom CRI-O
path, broken into phases — the restore-side counterpart to the checkpoint repo's
`benchmark/run.sh`.

It repeatedly applies a **ready restore-Pod manifest**, waits until the Pod is
Running, and extracts the phase breakdown from the node's logs:

| Phase | What | Source |
|---|---|---|
| `stage_s` | Custom CRI-O fetches the `.tar` + `.blob` onto the node | CRI-O journal: `restore annotation detected` -> `staged GPU data blob` |
| `criu_s` | CRIU restores CPU process **and** GPU control state (cuda_plugin) | restored container's `userdata/restore.log` (last timestamp) |
| `cuda_plugin_s` | ...of which the NVIDIA cuda_plugin control-state restore | `cuda_plugin` lines in `restore.log` |
| `remap_s` | interceptor re-maps GPU data from the `.blob` to the same VA (H2D) | restore-agent journal: `remapping GPU data` -> `GPU restore complete` |
| `total_s` | wall clock from `kubectl apply` until the Pod is Running/Ready | this script |

> Timeline note: the Pod reports **Running** once CRIU restore finishes; the
> interceptor **data remap** runs just after (driven by the restore-agent), so the app
> is fully usable at roughly `total_s + remap_s`. Both are reported separately.

## What YOU must set up first (manual steps)

1. **A working restore.** Get one successful restore first (see `docs/MIGRATION.ko.md`
   / `docs/SETUP.ko.md`). The benchmark only re-runs an existing restore; it does not
   fix a broken one.

2. **Socket-clean checkpoint.** The checkpoint must restore cleanly. A checkpoint whose
   workload held a TCP socket fails with `CRIU -52 / --tcp-close` (SETUP.ko.md §7) — make
   the source workload offline and re-checkpoint before benchmarking.

3. **A ready restore-Pod manifest** — generate once and reuse:

   ```bash
   ./scripts/gen-restore-pod.sh /mnt/nfs/gcr/<checkpoint>.tar \
     --name restore-bench --uid <source-pod-uid> --node <target-node> \
     --image <same image as the source pod> \
     --uri "nfs://<server>/<path>/<checkpoint>.tar" > deploy/restore-bench.yaml
   ```

4. **Pre-pull the restore image** on the target node so image-pull time does not skew
   `total_s` (manifest uses `imagePullPolicy: IfNotPresent`):

   ```bash
   sudo crictl pull <image>   # on the target node
   ```

5. **Free GPU on the target node** (single-GPU nodes: nothing else may hold the GPU;
   the source pod can stay on its own node, the restore lands on `--node`).

6. **Host access for the phase split.** CRI-O/restore-agent journals, `restore.log` and
   staged files live on the **target node**. Either:
   - run on the **master** with `NODE_SSH="ssh <target-node>"` (key-based SSH able to
     read `journalctl` and `/run/...`, i.e. root), or
   - run **on the target node** (with `kubectl` working there), leaving `NODE_SSH` empty.
   Without host access you still get `total_s`; per-phase columns stay blank.

## Run

```bash
RESTORE_YAML=deploy/restore-bench.yaml \
NODE_SSH="ssh jsj-worker-2" \
RUNS=5 \
./benchmark/restore-bench.sh
```

Output: `restore-bench.csv` (one row per run) + a median summary:

```
[bench] MEDIAN over 5 successful restore(s):
  total (to Running)        4.90 s
  stage (tar+blob)          2.40 s
  criu (cpu+control)        1.35 s
    cuda_plugin             0.60 s
  data remap (blob->GPU)    0.80 s
  tar size                  0.30 GB
  blob (GPU data)           2.86 GB
```

## Env knobs

| Var | Default | Meaning |
|---|---|---|
| `RESTORE_YAML` | (required) | the restore Pod manifest |
| `NODE_SSH` | `""` (local) | host cmd access to the target node, e.g. `ssh jsj-worker-2` |
| `RUNS` | `5` | repeats (median reported) |
| `TIMEOUT` | `600` | per-run seconds to reach Running |
| `OUT` | `restore-bench.csv` | results CSV |
| `CRIO_UNIT` / `AGENT_UNIT` | `crio` / `gpu-cr-restore-agent` | systemd units |
| `DATA_DIR` / `STAGE_DIR` | `/var/lib/gcr-data` / `/var/lib/gpu-cr/restore` | blob / staged-tar dirs |
| `KEEP_LAST` | `0` | `1` = leave the last restored pod running |

## Caveats

- Phase timestamps come from journald receive time; sub-100 ms splits are approximate.
- `restore.log` is only readable for **successful** restores (CRI-O removes it on
  failure), so `criu_s`/`cuda_plugin_s` are blank for failed runs.
- `remap_s` needs the restore-agent (crun path). If your runtime runs poststart hooks on
  restore, the hook does the remap and the agent line may be absent.
