#!/usr/bin/env bash
# From a list of checkpoints (name / uid / tar path), GENERATE a restore manifest for
# each, and optionally CHECK that each one restores (PASS/Running) — dumping the error
# (pod events + CRIU restore.log tail + CRI-O journal) when it FAILS.
#
# RUN ON THE TARGET GPU NODE, or run on the master with NODE_SSH="ssh <node>" (then tar
# reads + gen-restore-pod.sh run on the node, kubectl runs locally).
# gen-restore-pod.sh reads each tar's spec.dump and
# needs the NVIDIA driver mount sources to exist locally, and the NFS must be mounted
# so the tar path is readable. kubectl must work from here for CHECK=1 (else CHECK=0
# and apply the generated manifests from the master).
#
# INPUT (one line per checkpoint) via CKPTS_FILE or stdin. Each line just needs the
# source-pod-uid (a UUID) and the tar path (…/*.tar) somewhere on it; extra columns are
# ignored. The mode (gcr/baseline) is inferred from the name/path (contains "-gcr-" ->
# gcr, else baseline). This matches the `ls -l` / status table you already have, e.g.:
#
#   b-gcr-pytorch-gpt2-r1   2.0G 278M  2026-... 9aff2ad6-...-f5e5857bfbd0  /mnt/nfs/gcr/checkpoint-b-gcr-...-<ts>.tar
#
# Env:
#   SERVER=10.178.0.14        # NFS server IP for the nfs:// checkpoint-uri (required)
#   NODE=jsj-worker-2         # target node (nodeSelector). default: this host's name
#   IMAGE=pytorch/pytorch:2.6.0-cuda12.4-cudnn9-runtime   # restore image (match source)
#   OUTDIR=deploy/bench       # where manifests are written
#   CHECK=1                   # 1 = apply each + verify Running; 0 = only generate
#   TIMEOUT=600  KUBECTL=kubectl  NS=default
#   NODE_SSH="ssh jsj-worker-2"   # run node-only steps (tar read + gen) on the node
#   NODE_GEN=<path to gen-restore-pod.sh on the node>   # default: same path as here
#   CRIO_UNIT=crio            # for the failure dump
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"; repo="$(cd "$here/.." && pwd)"
GEN="$repo/scripts/gen-restore-pod.sh"
NODE_SSH=${NODE_SSH:-}
NODE_GEN=${NODE_GEN:-$GEN}
nrun(){ if [ -n "$NODE_SSH" ]; then $NODE_SSH "$@"; else "$@"; fi; }
SERVER=${SERVER:?set SERVER to the NFS server IP (e.g. 10.178.0.14)}
NODE=${NODE:-$(hostname)}
IMAGE=${IMAGE:-pytorch/pytorch:2.6.0-cuda12.4-cudnn9-runtime}
OUTDIR=${OUTDIR:-deploy/bench}; CHECK=${CHECK:-1}; TIMEOUT=${TIMEOUT:-600}
KUBECTL=${KUBECTL:-kubectl}; NS=${NS:-default}; CRIO_UNIT=${CRIO_UNIT:-crio}
[ -x "$GEN" ] || { echo "cannot find $GEN"; exit 1; }
mkdir -p "$OUTDIR"
now(){ date +%s.%N; }; elapsed(){ awk "BEGIN{printf \"%.1f\", $(now)-$1}"; }

src="${CKPTS_FILE:-/dev/stdin}"
[ "$src" = /dev/stdin ] && echo "[check] reading checkpoint list from stdin (paste rows, Ctrl-D to end):" >&2

printf '%-40s %-9s %-6s %-8s %s\n' "manifest" "mode" "check" "time_s" "note"
FAIL=0; N=0
while IFS= read -r line; do
  [ -z "${line// }" ] && continue
  uid=$(grep -oE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' <<<"$line" | head -1)
  tar=$(grep -oE '/[^ ]*\.tar' <<<"$line" | head -1)
  [ -n "$uid" ] && [ -n "$tar" ] || { echo "  (skip: no uid/tar in: $line)"; continue; }
  base=$(basename "$tar" .tar)
  case "$tar$base" in *-gcr-*) mode=gcr;; *baseline*) mode=baseline;; *) mode=gcr;; esac
  # checkpoint name = checkpoint-<PODNAME>_<ns>-<ctr>-<ts>; restore name = r-<PODNAME>
  podname=${base#checkpoint-}; podname=${podname%%_*}
  rname=$(echo "r-$podname" | tr '._' '--' | tr '[:upper:]' '[:lower:]' | cut -c1-58 | sed 's/-*$//')
  yaml="$OUTDIR/$rname.yaml"
  N=$((N+1))

  if ! nrun test -f "$tar"; then
    printf '%-40s %-9s %-6s %-8s %s\n' "$rname" "$mode" "-" "-" "MISSING tar $tar (NFS mounted on the node?)"; FAIL=$((FAIL+1)); continue
  fi
  if [ -n "$NODE_SSH" ]; then
    $NODE_SSH "$NODE_GEN '$tar' --name '$rname' --uid '$uid' --node '$NODE' --image '$IMAGE' --uri 'nfs://$SERVER$tar'" > "$yaml" 2>/tmp/gen.err || { printf '%-40s %-9s %-6s %-8s %s\n' "$rname" "$mode" "GENERR" "-" "$(tail -1 /tmp/gen.err)"; FAIL=$((FAIL+1)); continue; }
  else
    "$GEN" "$tar" --name "$rname" --uid "$uid" --node "$NODE" --image "$IMAGE" --uri "nfs://$SERVER$tar" > "$yaml" 2>/tmp/gen.err || { printf '%-40s %-9s %-6s %-8s %s\n' "$rname" "$mode" "GENERR" "-" "$(tail -1 /tmp/gen.err)"; FAIL=$((FAIL+1)); continue; }
  fi
  [ -s "$yaml" ] || { printf '%-40s %-9s %-6s %-8s %s\n' "$rname" "$mode" "GENERR" "-" "empty manifest"; FAIL=$((FAIL+1)); continue; }

  if [ "$CHECK" != 1 ]; then
    printf '%-40s %-9s %-6s %-8s %s\n' "$rname" "$mode" "gen" "-" "$yaml"; continue
  fi

  # apply + wait for Running / failure
  $KUBECTL -n "$NS" delete pod "$rname" --force --grace-period=0 >/dev/null 2>&1 || true
  local_since=$(( $(date +%s) - 2 ))
  t0=$(now)
  if ! $KUBECTL -n "$NS" apply -f "$yaml" >/dev/null 2>&1; then
    printf '%-40s %-9s %-6s %-8s %s\n' "$rname" "$mode" "APPLYERR" "-" "kubectl apply failed"; FAIL=$((FAIL+1)); continue
  fi
  ready=""; phase=""
  while awk "BEGIN{exit !($(elapsed "$t0")<$TIMEOUT)}"; do
    ready=$($KUBECTL -n "$NS" get pod "$rname" -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null||echo "")
    phase=$($KUBECTL -n "$NS" get pod "$rname" -o jsonpath='{.status.phase}' 2>/dev/null||echo "")
    [ "$ready" = true ] && break
    [ "$phase" = Failed ] && break
    sleep 2
  done
  tsec=$(elapsed "$t0")
  if [ "$ready" = true ]; then
    printf '%-40s %-9s %-6s %-8s %s\n' "$rname" "$mode" "PASS" "$tsec" "Running"
  else
    printf '%-40s %-9s %-6s %-8s %s\n' "$rname" "$mode" "FAIL" "$tsec" "phase=${phase:-?} -> see dump below"
    FAIL=$((FAIL+1))
    echo "  ----- FAIL dump: $rname -----"
    $KUBECTL -n "$NS" describe pod "$rname" 2>/dev/null | sed -n '/Events:/,$p' | tail -10 | sed 's/^/    /'
    cid=$($KUBECTL -n "$NS" get pod "$rname" -o jsonpath='{.status.containerStatuses[0].containerID}' 2>/dev/null | sed 's#.*/##')
    if [ -n "$cid" ]; then
      echo "    -- CRIU restore.log tail --"
      tail -n 8 "/run/containers/storage/overlay-containers/$cid/userdata/restore.log" 2>/dev/null | sed 's/^/    /' || echo "    (restore.log already gone; catch it with benchmark/README §capture)"
    fi
    echo "    -- crio journal (gpu-cr/criu) --"
    journalctl -u "$CRIO_UNIT" --since "@$local_since" --no-pager 2>/dev/null | grep -iE 'gpu-cr|criu|restor' | tail -6 | sed 's/^/    /'
    echo "  ------------------------------"
  fi
  $KUBECTL -n "$NS" delete pod "$rname" --force --grace-period=0 >/dev/null 2>&1 || true
done < "$src"

echo
echo "[check] $N checkpoint(s), $FAIL failed. Manifests in $OUTDIR/"
[ "$CHECK" = 1 ] && echo "[check] PASS ones can be fed to restore-bench.sh (GCR_YAML/BASE_YAML)."
