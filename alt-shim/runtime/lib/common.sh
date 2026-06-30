#!/usr/bin/env bash
# common.sh — shared helpers for the restore shim.
# Sourced by gpu-cr-restore-shim and the lib/*.sh modules.

# Where per-container restore state (markers, pidfiles, staged images) lives.
GCR_STATE_DIR="${GCR_STATE_DIR:-/var/lib/gpu-cr/restore}"

gcr_log() { echo "[gpu-cr-restore][$(date +%H:%M:%S)] $*" >&2; }
gcr_die() { gcr_log "FATAL: $*"; exit 1; }

gcr_rundir() {
  local cid="$1"; local d="${GCR_STATE_DIR}/${cid}"
  mkdir -p "$d"; echo "$d"
}
gcr_marker() { echo "${GCR_STATE_DIR}/$1/.restored"; }

# gcr_annotation <config.json> <key> -> prints the annotation value (or empty).
# Uses jq when present, else python3, else a grep fallback. No hard dependency
# beyond what a CRI-O node already ships.
gcr_annotation() {
  local cfg="$1" key="$2"
  if command -v jq >/dev/null 2>&1; then
    jq -r --arg k "$key" '.annotations[$k] // empty' "$cfg" 2>/dev/null
  elif command -v python3 >/dev/null 2>&1; then
    python3 - "$cfg" "$key" <<'PY' 2>/dev/null
import json,sys
cfg,key=sys.argv[1],sys.argv[2]
try:
    print(json.load(open(cfg)).get("annotations",{}).get(key,""))
except Exception:
    print("")
PY
  else
    # crude fallback: matches "key": "value" on one line.
    grep -o "\"${key}\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" "$cfg" \
      | sed 's/.*:[[:space:]]*"\([^"]*\)"/\1/' | head -n1
  fi
}
