#!/usr/bin/env bash
# common.sh — shared helpers for the validation suite.
# Source from every run.sh:  . "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"

set -uo pipefail   # NOT -e: a failing check must be recorded, not fatal

# ---- knobs (override via env) ------------------------------------------------
NS="${NS:-default}"
MERGED_NODE="${MERGED_NODE:-jsj-worker-1}"      # node running the MERGED CRI-O (D)
CONTROL_NODE="${CONTROL_NODE:-jsj-worker-2}"    # node kept on the PRE-MERGE binary
NFS_ENDPOINT="${NFS_ENDPOINT:-10.178.0.14}"     # cross-node staging source
NFS_PATH="${NFS_PATH:-/mnt/nfs}"
TIMEOUT="${TIMEOUT:-300}"

RESULTS_ROOT="${RESULTS_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/results}"
RUN_ID="${RUN_ID:-$(date +%Y%m%d-%H%M%S)}"
OUTDIR=""

# ---- output ------------------------------------------------------------------
_c()   { printf '\033[%sm%s\033[0m' "$1" "$2"; }
info() { echo "$(_c '1;34' '[INFO]') $*"; }
ok()   { echo "$(_c '1;32' '[ PASS ]') $*"; }
bad()  { echo "$(_c '1;31' '[ FAIL ]') $*"; }
warn() { echo "$(_c '1;33' '[ WARN ]') $*"; }
step() { echo; echo "$(_c '1;36' "=== $* ===")"; }

FAILURES=0
PASSES=0

# check <description> <command...>
#   The command runs here, so nothing upstream can abort the script.
check() {
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then
    ok "$desc"; PASSES=$((PASSES+1))
  else
    bad "$desc"; FAILURES=$((FAILURES+1))
  fi
}

# negation helper:  check "no foo" not grep -q foo file
not() { ! "$@"; }

# record a failure without running a command
fail() { bad "$*"; FAILURES=$((FAILURES+1)); }

finish() {
  echo
  echo "----------------------------------------"
  if [ "$FAILURES" -eq 0 ]; then
    ok "ALL CHECKS PASSED ($PASSES)"
  else
    bad "$FAILURES FAILED / $PASSES passed"
  fi
  [ -n "$OUTDIR" ] && info "artifacts: $OUTDIR"
  exit "$FAILURES"
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
    [ "$cur" = "Failed" ] && return 1
    sleep 2; i=$((i+2))
  done
  return 1
}

wait_log() { # wait_log <pod> <regex> [timeout]
  local pod="$1" re="$2" t="${3:-$TIMEOUT}" i=0
  while [ "$i" -lt "$t" ]; do
    kubectl -n "$NS" logs "$pod" 2>/dev/null | grep -qE "$re" && return 0
    sleep 2; i=$((i+2))
  done
  return 1
}

pod_uid()  { kubectl -n "$NS" get pod "$1" -o jsonpath='{.metadata.uid}' 2>/dev/null || true; }
pod_node() { kubectl -n "$NS" get pod "$1" -o jsonpath='{.spec.nodeName}' 2>/dev/null || true; }

# Last "CHECKSUM <sha256>" the workload emitted. Never fails.
pod_checksum() {
  kubectl -n "$NS" logs "$1" 2>/dev/null \
    | grep -oE 'CHECKSUM [0-9a-f]{64}' | tail -1 | awk '{print $2}' || true
}

# ---- node-side log capture ----------------------------------------------------
# Run the suite on the node, or have passwordless ssh to it.
node_journal() { # node_journal <node> <since> <outfile>
  local node="$1" since="$2" out="$3"
  : > "$out"
  if [ "$(hostname)" = "$node" ] || [ "$(hostname -s 2>/dev/null)" = "${node%%.*}" ]; then
    sudo journalctl -u crio --since "$since" --no-pager >> "$out" 2>&1 || true
  else
    ssh -o BatchMode=yes "$node" "sudo journalctl -u crio --since '$since' --no-pager" >> "$out" 2>&1 \
      || warn "could not pull the journal from $node — collect it manually into $out"
  fi
}

# require_journal <file> <node>
#   An EMPTY journal must not read as "the bad log line is absent". Guard every
#   log-based check with this.
require_journal() {
  [ -s "$1" ] && return 0
  fail "no CRI-O journal collected from $2 - log-based checks cannot be evaluated"
  warn "  either run this suite on $2, or enable passwordless ssh to it:"
  warn "    ssh-copy-id root@$2"
  return 1
}

render_manifest() { envsubst < "$1"; }
