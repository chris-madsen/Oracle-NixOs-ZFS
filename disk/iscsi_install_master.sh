#!/usr/bin/env bash
set -euo pipefail

# CONFIGURATION
ISCSI_IQN="iqn.2015-02.oracle.boot:uefi"
ISCSI_IP="169.254.2.3"
NIXPKGS="https://github.com/NixOS/nixpkgs/archive/nixos-unstable.tar.gz"
CLIENT_INITIATOR="iqn.2024-01.com.nixos:installer"

export PATH="/root/.nix-profile/sbin:/root/.nix-profile/bin:$PATH"

echo ">>> [ISCSI] Step 1: Ensure tools"
if ! command -v iscsiadm >/dev/null 2>&1; then
  NIX_PATH="nixpkgs=$NIXPKGS" nix-env -f '<nixpkgs>' -iA openiscsi iputils
fi

echo ">>> [ISCSI] Step 2: Network check"
if ! ping -c 3 -W 2 "$ISCSI_IP" >/dev/null 2>&1; then
  echo "ERROR: Target IP $ISCSI_IP is NOT reachable."
  exit 1
fi

echo ">>> [ISCSI] Step 3: Initiator name"
mkdir -p /etc/iscsi
echo "InitiatorName=$CLIENT_INITIATOR" > /etc/iscsi/initiatorname.iscsi

echo ">>> [ISCSI] Step 4: Kernel module"
modprobe iscsi_tcp || true
mkdir -p /etc/modules-load.d
echo "iscsi_tcp" > /etc/modules-load.d/iscsi.conf

echo ">>> [ISCSI] Step 5: start iscsid + login (runtime)"
if command -v systemd-run >/dev/null 2>&1; then
  systemd-run --unit=iscsid-manual --property=Restart=on-failure \
    /root/.nix-profile/sbin/iscsid -f || true
  systemctl start iscsid-manual.service >/dev/null 2>&1 || true
  systemd-run --unit=iscsi-login --property=RemainAfterExit=yes \
    /root/.nix-profile/sbin/iscsiadm -m discovery -t sendtargets -p "${ISCSI_IP}:3260" || true
  systemctl start iscsi-login.service >/dev/null 2>&1 || true
  /root/.nix-profile/sbin/iscsiadm -m node -T "$ISCSI_IQN" -p "${ISCSI_IP}:3260" -l || true
else
  /root/.nix-profile/sbin/iscsid -f >/var/log/iscsid.log 2>&1 &
  sleep 2
  /root/.nix-profile/sbin/iscsiadm -m discovery -t sendtargets -p "${ISCSI_IP}:3260"
  /root/.nix-profile/sbin/iscsiadm -m node -T "$ISCSI_IQN" -p "${ISCSI_IP}:3260" -l
fi

echo ">>> [ISCSI] Step 5b: enable auto-login for future boots (if iscsid runs)"
/root/.nix-profile/sbin/iscsiadm -m node -T "$ISCSI_IQN" -p "${ISCSI_IP}:3260" \
  -o update -n node.startup -v automatic || true

echo ">>> [ISCSI] Step 6: Verification"
sleep 3
iscsiadm -m session || true
lsblk | grep sd || echo "No sdX devices found."
