#!/usr/bin/env bash
set -euo pipefail

LOG_FILE="/var/log/nixos-install.log"
exec > >(tee -a "$LOG_FILE" /dev/console) 2>&1

echo ">>> [AUTO-INSTALL] Start..."
ISCSI_IP="169.254.2.3"
ISCSI_IQN="iqn.2015-02.oracle.boot:uefi"
CLIENT_INITIATOR="iqn.2024-01.com.nixos:installer"
INSTALL_REBOOT="${INSTALL_REBOOT:-0}"
ZFS_FLAKE="${ZFS_FLAKE:-github:NixOS/nixpkgs/nixos-24.11}"

ROOT_SRC="$(findmnt -n -o SOURCE / || true)"
if echo "$ROOT_SRC" | grep -q '^/dev/sdb'; then
    echo "FATAL: Refusing to run when root is on /dev/sdb."
    exit 1
fi

echo ">>> [STEP 1] Waiting for Network..."
while ! ping -c 1 -W 1 $ISCSI_IP > /dev/null 2>&1; do
    echo "Waiting for target $ISCSI_IP..."
    sleep 2
done

echo ">>> [STEP 2] Init iSCSI..."
modprobe iscsi_tcp
mkdir -p /etc/iscsi
echo "InitiatorName=$CLIENT_INITIATOR" > /etc/iscsi/initiatorname.iscsi
pkill iscsid || true
iscsid
sleep 3

echo ">>> [STEP 3] Discovery & Login..."
# Пытаемся подключиться, игнорируя ошибку "уже подключен"
iscsiadm -m discovery -t sendtargets -p $ISCSI_IP:3260 || true
iscsiadm -m node -T $ISCSI_IQN -p $ISCSI_IP:3260 -l || true

echo ">>> [STEP 4] Waiting for /dev/sdb..."
for i in {1..20}; do
    if lsblk | grep -q sdb; then
        echo "Disk found!"
        break
    fi
    sleep 2
done

if ! lsblk | grep -q sdb; then
    echo "FATAL: /dev/sdb not found! Run iscsi_install_master.sh first."
    exit 1
fi

echo ">>> [STEP 4b] Loading ZFS module..."
if ! modprobe zfs; then
    echo ">>> [STEP 4b] ZFS module missing, building via nix..."
    zfs_attr="$(nix --extra-experimental-features "nix-command flakes" eval --raw "${ZFS_FLAKE}#zfs.kernelModuleAttribute")"
    nix --extra-experimental-features "nix-command flakes" build --out-link ./result "${ZFS_FLAKE}#linuxPackages_6_6.${zfs_attr}"
    if [ -d ./result/lib/modules/"$(uname -r)" ]; then
        if ! command -v depmod >/dev/null 2>&1; then
            nix-env -f '<nixpkgs>' -iA kmod || true
        fi
        base_mod="/run/booted-system/kernel-modules/lib/modules/$(uname -r)"
        tmp_mod="/tmp/zfs-mods-$(uname -r)"
        rm -rf "$tmp_mod"
        mkdir -p "$tmp_mod/lib/modules"
        if [ -d "$base_mod" ]; then
            cp -a "$base_mod" "$tmp_mod/lib/modules/" || true
        else
            mkdir -p "$tmp_mod/lib/modules/$(uname -r)"
        fi
        mkdir -p "$tmp_mod/lib/modules/$(uname -r)/extra"
        cp -a ./result/lib/modules/"$(uname -r)"/extra/*.ko* "$tmp_mod/lib/modules/$(uname -r)/extra/" || true
        depmod -b "$tmp_mod" "$(uname -r)" || true
        # -d expects a root that contains lib/modules/<ver>
        modprobe -d "$tmp_mod" zfs || true
    fi
    if ! lsmod | grep -q '^zfs'; then
        echo "FATAL: zfs module not available in current kernel."
        exit 1
    fi
fi

echo ">>> [STEP 5] Installing..."
nix --extra-experimental-features "nix-command flakes" \
    run github:nix-community/disko -- --mode disko /root/installer/disk-config.nix

nixos-install --no-root-passwd --flake /root/installer#default

echo ">>> [SUCCESS] Install finished."
sync
sleep 2
if [ "$INSTALL_REBOOT" -eq 1 ]; then
    echo ">>> [INFO] Rebooting as requested..."
    reboot
else
    echo ">>> [INFO] Skipping reboot. Detach current boot volume and attach the ZFS boot volume as boot."
fi
