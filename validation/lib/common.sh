#!/usr/bin/env bash
# common.sh — shared helpers for the validation suite.
# Source this from every run.sh:  . "$(dirname "$0")/../lib/common.sh"

set -euo pipefail

# ---- knobs (override via env) ------------------------------------------------
NS="${NS:-default}"
MERGED_NODE="${MERGED_NODE:-jsj-worker-1}"      # node running the MERGED CRI-O (D)
CONTROL_NODE="${CONTROL_NODE:-jsj-worker-2}"    # node kept on the PRE-MERGE binary
NFS_ENDPOINT="${NFS_ENDPOINT:-10.178.0.14}"     # cross-node staging source
NFS_PATH="${NFS_PATH:-/mnt/nfs}"
TIMEOUT="${TIMEOUT:-300}"

RESULTS_ROOT="${RESULTS_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/results}"
RUN_ID="${RUN_ID:-$(date +%Y%m%d-%H%M%S)}"

# ---- output ------------------------------------------------------------------
_c() { printf '\033[%sm%s\033[0m' "$1" "$2"; }
info() { echo "$(_c '1;34' '[INFO]') $*"; }
ok()   { echo "$(_c '1;32' '[ PASS ]') $*"; }
bad()  { echo "$(_c '1;31' '[ FAIL ]') $*"; }
warn() { echo "$(_c '1;33' '[ WARN ]') $*"; }
step() { echo; echo "$(_c '1;36' "=== $* ===")"; }

FAILURES=0
check() { # check <description> <0|1 result>
  if [ "$2" -eq 0 ]; then ok "$1"; else bad "$1"; FAILURES=$((FAILURES+1)); fi
}
finish() {
  echo
  if [ "$FAILURES" -eq 0 ]; then ok "ALL CHECKS PASSED"; else bad "$FAILURES CHECK(S) FAILED"; fi
  info "artifacts: ${OUTDIR:-<none>}"
  return "$FAILURES"
}

outdir() { # outdir <test-name>
  OUTDIR="${RESULTS_ROOT}/${RUN_ID}-$1"
  mkdir -p "$OUTDIR"
  info "results -> $OUTDIR"
}

# ---- kube helpers -------------------------------------------------------------
wait_pod_phase() { # wait_pod_phase <pod> <phase> [timeout]
  local pod="$1" want="$2" t="${3:-$TIMEOUT}" i=0 cur=
  while [ "$i" -lt "$t" ]; do
    cur="$(kubectl -n "$NS" get pod "$pod" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    [ "$cur" = "$want" ] && return 0
    [ "$cur" = "Failed" ] && { bad "pod $pod entered Failed"; return 1; }
    sleep 2; i=$((i+2))
  done
  bad "timeout waiting for $pod to reach $want (last: ${cur:-<none>})"
  return 1
}

wait_log() { # wait_log <pod> <regex> [timeout]
  local pod="$1" re="$2" t="${3:-$TIMEOUT}" i=0
  while [ "$i" -lt "$t" ]; do
    if kubectl -n "$NS" logs "$pod" 2>/dev/null | grep -qE "$re"; then return 0; fi
    sleep 2; i=$((i+2))
  done
  bad "timeout waiting for /$re/ in $pod logs"
  return 1
}

pod_uid()  { kubectl -n "$NS" get pod "$1" -o jsonpath='{.metadata.uid}'; }
pod_node() { kubectl -n "$NS" get pod "$1" -o jsonpath='{.spec.nodeName}'; }

# Extract the LAST "CHECKSUM <sha>" emitted by the workload.
pod_checksum() { kubectl -n "$NS" logs "$1" 2>/dev/null | grep -oE 'CHECKSUM [0-9a-f]{64}' | tail -1 | awk '{print $2}'; }

# ---- node-side log capture ----------------------------------------------------
# Requires passwordless ssh to the node, or run the suite ON the node.
node_journal() { # node_journal <node> <since> <outfile>
  local node="$1" since="$2" out="$3"
  if [ "$(hostname)" = "$node" ]; then
    sudo journalctl -u crio --since "$since" --no-pager > "$out" 2>&1 || true
  else
    ssh "$node" "sudo journalctl -u crio --since '$since' --no-pager" > "$out" 2>&1 || \
      warn "could not collect journal from $node (ssh?). Collect manually into $out"
  fi
}

render_manifest() { # render_manifest <file>  -> stdout with ${VARS} substituted
  envsubst < "$1"
}
