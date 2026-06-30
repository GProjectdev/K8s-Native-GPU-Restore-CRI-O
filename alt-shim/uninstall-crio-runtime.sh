#!/usr/bin/env bash
set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "run as root"; exit 1; }
rm -f /etc/crio/crio.conf.d/99-gpu-cr-restore.conf
rm -f /usr/local/bin/gpu-cr-restore-shim
rm -rf /usr/local/lib/gpu-cr-restore
systemctl restart crio || true
echo "uninstalled gpu-cr-restore runtime handler"
