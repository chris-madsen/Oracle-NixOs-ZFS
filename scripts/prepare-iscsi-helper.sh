#!/usr/bin/env bash
set -euo pipefail

PORTAL="${PORTAL:-169.254.2.6}"
PORT="${PORT:-3260}"
IQN="${IQN:-iqn.2015-02.oracle.boot:uefi}"
LUN="${LUN:-0}"

modules=("iscsi_tcp" "scsi_transport_iscsi")
for mod in "${modules[@]}"; do
  if ! lsmod | grep -q "^${mod}"; then
    echo "Loading module ${mod}..."
    modprobe "$mod"
  fi
done

if ! command -v iscsiadm >/dev/null 2>&1; then
  echo "ERROR: iscsiadm not installed. Install iscsi-initiator-utils (use packages or Nix) before proceeding."
  exit 1
fi

echo "Discovering iSCSI target ${IQN} at ${PORTAL}:${PORT}..."
iscsiadm -m discovery -t sendtargets -p "${PORTAL}:${PORT}"

echo "Configuring login for ${IQN}..."
iscsiadm -m node -T "${IQN}" -p "${PORTAL}:${PORT}" --op update -n node.startup -v automatic || true
iscsiadm -m node -T "${IQN}" -p "${PORTAL}:${PORT}" -l

target="/dev/disk/by-path/ip-${PORTAL}:${PORT}-iscsi-${IQN}-lun-${LUN}"
echo "Waiting for target device ${target}..."
for i in {1..6}; do
  if [ -e "$target" ]; then
    ls -l "$target"
    exit 0
  fi
  sleep 2
done

echo "ERROR: Target device ${target} did not appear."
exit 1
