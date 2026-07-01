#!/usr/bin/env bash
# Turn CRI-O's "restoring ... expects following bind mounts defined (A,B,C)" list
# into Pod volumeMounts + volumes so the restore passes CRI-O's mount check.
#
# CRI-O's restore validates that every bind mount recorded in the checkpoint has a
# matching ContainerPath in the new Pod's CRI mounts (server/container_restore.go).
# The NVIDIA driver libs/binaries were injected by nvidia-container-runtime at the
# ORIGINAL container's creation; on restore they must be provided explicitly.
#
# Usage:
#   ./scripts/gen-nvidia-restore-mounts.sh "A,B,C,..."        # paste the (...) list
#   ./scripts/gen-nvidia-restore-mounts.sh < list.txt          # or via stdin
# Emits two YAML blocks (volumeMounts then volumes) to stdout.
set -euo pipefail
raw="${1:-$(cat)}"
IFS=',' read -ra P <<< "$(echo "$raw" | tr -d '[:space:]')"
echo "      # --- NVIDIA driver bind mounts the checkpoint expects (${#P[@]}) ---"
echo "      volumeMounts:"
i=0; for p in "${P[@]}"; do [ -n "$p" ] && echo "        - { name: nv$i, mountPath: $p, readOnly: true }"; i=$((i+1)); done
echo "  # --- volumes ---"
echo "  volumes:"
i=0; for p in "${P[@]}"; do [ -n "$p" ] && echo "    - { name: nv$i, hostPath: { path: $p } }"; i=$((i+1)); done
