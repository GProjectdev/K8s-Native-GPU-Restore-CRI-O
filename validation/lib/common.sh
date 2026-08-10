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
  [ -n "$CLEANUP_PODS" ] && info "cleaning up:$CLEANUP_PODS"
  exit "$FAILURES"    # EXIT trap removes the pods
}

outdir() { # outdir <test-name>
  OUTDIR="${RESULTS_ROOT}/${RUN_ID}-$1"
  mkdir -p "$OUTDIR"
  info "results -> $OUTDIR"
}

# Print, at the start of a test, how to capture the journal by hand in a second
# terminal. Cheaper than setting up ssh if you only need one run.
announce_journal_hint() { # announce_journal_hint <node> <since>
  [ -n "${CRIO_LOG:-}" ] && return 0
  if [ "$(hostname)" != "$1" ] && ! ssh -o BatchMode=yes -o ConnectTimeout=5 "$1" true 2>/dev/null; then
    warn "no ssh to $1 — to capture CRI-O logs, run this on $1 in another terminal NOW:"
    warn "    journalctl -u crio --since '$2' -f | tee /tmp/crio.log"
    warn "then Ctrl-C when this test finishes and re-run with CRIO_LOG=/tmp/crio.log"
    echo
  fi
}

# ---- cleanup -----------------------------------------------------------------
# Pods must be removed however the script ends -- success, a failed check, Ctrl-C.
# A pod left in CreateContainerError is retried by kubelet every ~13s and floods
# the CRI-O journal, which then poisons the next test's log analysis.
CLEANUP_PODS=""
register_cleanup() { CLEANUP_PODS="$CLEANUP_PODS $*"; }

cleanup_on_exit() {
  [ -n "$CLEANUP_PODS" ] || return 0
  # shellcheck disable=SC2086
  kubectl -n "$NS" delete pod $CLEANUP_PODS --ignore-not-found --wait=false >/dev/null 2>&1 || true
}
trap cleanup_on_exit EXIT INT TERM

# ---- reading artifacts from earlier tests ------------------------------------
# Never `cat results/*-<test>/<file>`: a rerun leaves several matching dirs and
# the glob concatenates them. Always take the newest.
latest_result() {   # latest_result <dir-suffix-glob>   -> newest matching dir
  ls -1dt "${RESULTS_ROOT}"/*-$1 2>/dev/null | head -1
}

read_artifact() {   # read_artifact <dir> <filename>    -> first line, trimmed
  [ -n "$1" ] && [ -f "$1/$2" ] || return 1
  head -1 "$1/$2" | tr -d '[:space:]'
}

# Quiet predicate: is this a single whitespace-free token?
is_single_token() {
  case "$1" in
    "" | *[[:space:]]* ) return 1 ;;
    * ) return 0 ;;
  esac
}

# Prefer an env-supplied value, but fall back to the artifact when the env value
# is malformed. A stale `export FOO=$(cat results/*-x/foo)` from an earlier
# attempt outlives the shell command that set it and would otherwise beat the
# auto-discovery with two concatenated values.
prefer_env_else_artifact() {   # <env-value> <dir> <file> <name-for-messages>
  if is_single_token "$1"; then printf '%s' "$1"; return 0; fi
  [ -n "$1" ] && warn "$4 from the environment is malformed; re-reading from $2 (unset it to silence this)" >&2
  read_artifact "$2" "$3"
}

# A value that should be a single token. Catches the concatenated-glob mistake.
require_single_token() {  # require_single_token <name> <value>
  case "$2" in
    "" ) fail "$1 is empty"; return 1 ;;
    *[[:space:]]* ) fail "$1 contains whitespace — looks like several files were concatenated: '$2'"
                    warn "  use the newest results dir only (latest_result)"; return 1 ;;
  esac
  return 0
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

# ---- running commands on a node ----------------------------------------------
# can_reach_node <node> -> 0 if we are that node, or ssh works
can_reach_node() {
  [ "$(hostname)" = "$1" ] && return 0
  [ "$(hostname -s 2>/dev/null)" = "${1%%.*}" ] && return 0
  ssh -o BatchMode=yes -o ConnectTimeout=5 "$1" true 2>/dev/null
}

# node_run <node> <command...> -- locally if we are the node, else over ssh
node_run() {
  local node="$1"; shift
  if [ "$(hostname)" = "$node" ] || [ "$(hostname -s 2>/dev/null)" = "${node%%.*}" ]; then
    "$@"
  else
    ssh -o BatchMode=yes -o ConnectTimeout=5 "$node" "$@"
  fi
}

# ---- node-side log capture ----------------------------------------------------
# Three ways to get the CRI-O journal, tried in order:
#   1. CRIO_LOG=<file>  — a journal you collected yourself (no ssh needed)
#   2. local journalctl — when the suite runs on the target node
#   3. ssh              — key-based access to the target node
# If all three fail, print the exact command to run on the node.
node_journal() { # node_journal <node> <since> <outfile>
  local node="$1" since="$2" out="$3"
  : > "$out"

  if [ -n "${CRIO_LOG:-}" ] && [ -f "${CRIO_LOG}" ]; then
    cat "${CRIO_LOG}" > "$out"
    info "using the pre-collected journal: ${CRIO_LOG}"
    return 0
  fi

  if [ "$(hostname)" = "$node" ] || [ "$(hostname -s 2>/dev/null)" = "${node%%.*}" ]; then
    journalctl -u crio --since "$since" --no-pager >> "$out" 2>&1 || true
    [ -s "$out" ] && return 0
  elif ssh -o BatchMode=yes -o ConnectTimeout=5 "$node" true 2>/dev/null; then
    ssh -o BatchMode=yes "$node" "journalctl -u crio --since '$since' --no-pager" >> "$out" 2>&1 || true
    [ -s "$out" ] && return 0
  fi

  warn "could not collect the CRI-O journal from $node"
  warn "run this ON $node:"
  warn "    journalctl -u crio --since '$since' --no-pager > /tmp/crio.log"
  warn "then re-run this test with:"
  warn "    CRIO_LOG=/tmp/crio.log $0"
  warn "(scp it over first if you are not on $node)"
  return 1
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
