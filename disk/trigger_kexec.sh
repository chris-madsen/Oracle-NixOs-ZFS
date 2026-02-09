#!/usr/bin/env bash
set -euo pipefail

log_targets=(/var/log/nixos-inject.log)
for dev in /dev/console /dev/ttyAMA0; do
  if [ -c "$dev" ] && [ -w "$dev" ]; then
    log_targets+=("$dev")
  fi
done
exec > >(tee -a "${log_targets[@]}") 2>&1

if [ ! -x /root/installer/iscsi_install_master.sh ]; then
  echo "ERROR: /root/installer/iscsi_install_master.sh not found or not executable."
  exit 1
fi
if [ ! -x /root/installer/install.sh ]; then
  echo "ERROR: /root/installer/install.sh not found or not executable."
  exit 1
fi

echo ">>> [INJECT] 1. Ensure iSCSI session"
/root/installer/iscsi_install_master.sh

echo ">>> [INJECT] 2. Install ZFS system onto /dev/sdb"
/root/installer/install.sh

echo ">>> [INJECT] Done. Stop instance, detach current boot volume, attach the new ZFS boot volume as boot."
