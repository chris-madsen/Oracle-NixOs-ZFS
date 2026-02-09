#!/usr/bin/env bash
set -euxo pipefail

if [ "$(id -u)" -ne 0 ]; then
  exec sudo -E bash "$0" "$@"
fi

log_targets=(/var/log/nixos-install.log)
for dev in /dev/console /dev/ttyAMA0 /dev/ttyS0 /dev/tty; do
  if [ -c "$dev" ] && [ -w "$dev" ]; then
    log_targets+=("$dev")
  fi
done
exec > >(tee -a "${log_targets[@]}") 2>&1

os_id=""
if [ -r /etc/os-release ]; then
  . /etc/os-release
  os_id="${ID:-}"
fi
if [ "$os_id" != "nixos" ]; then
  echo "Refusing to run: expected NixOS installer (ID=nixos), got '${os_id:-unknown}'"
  exit 1
fi

root_src="$(findmnt -n -o SOURCE / || true)"
root_fs="$(findmnt -n -o FSTYPE / || true)"
if [ "$root_src" = "/dev/sda1" ] || [ "$root_fs" = "ext4" ]; then
  echo "Refusing to run on root=$root_src fstype=$root_fs"
  exit 1
fi

export NIX_CONFIG="experimental-features = nix-command flakes"
udevadm settle

if grep -q "/dev/sda" /root/installer/disk-config.nix; then
  echo "Refusing to run: disk-config references /dev/sda (temp OS must remain untouched)." >&2
  exit 1
fi

if ! modprobe dm_thin_pool; then
  echo "WARNING: dm_thin_pool module missing; continuing anyway." >&2
fi

i=0
while ! ip route get 1.1.1.1 >/dev/null 2>&1; do
  i=$((i + 1))
  if [ "$i" -ge 60 ]; then
    echo "Network not ready after 5 minutes." >&2
    break
  fi
  sleep 5
done

cd /root/installer
rm -f result
nix build --no-write-lock-file .#nixosConfigurations.default.config.system.build.disko
disko_script="$(readlink -f result)"
"$disko_script"

if ! zpool list -H zroot >/dev/null 2>&1; then
  echo "ERROR: zpool 'zroot' not found after disko. Refusing to install." >&2
  exit 1
fi
if ! vgs data_vg >/dev/null 2>&1; then
  echo "ERROR: LVM VG 'data_vg' not found after disko. Refusing to install." >&2
  exit 1
fi
if ! lvs data_vg/thinpool >/dev/null 2>&1; then
  echo "ERROR: LVM thinpool 'data_vg/thinpool' not found after disko. Refusing to install." >&2
  exit 1
fi
if ! lvs data_vg/data >/dev/null 2>&1; then
  echo "ERROR: LVM thin LV 'data_vg/data' not found after disko. Refusing to install." >&2
  exit 1
fi
if ! findmnt -n /boot >/dev/null 2>&1; then
  echo "ERROR: /boot not mounted after disko. Refusing to install." >&2
  exit 1
fi

if [ "${NIXOS_SNAPSHOT_GATE:-0}" = "1" ]; then
  wait_sec="${NIXOS_SNAPSHOT_WAIT_SEC:-900}"
  echo "Snapshot gate enabled. Waiting up to ${wait_sec}s for /root/installer/SNAPSHOT_DONE..."
  end=$((SECONDS + wait_sec))
  while [ ! -f /root/installer/SNAPSHOT_DONE ] && [ "$SECONDS" -lt "$end" ]; do
    sleep 5
  done
  if [ ! -f /root/installer/SNAPSHOT_DONE ]; then
    echo "Snapshot gate timeout reached; continuing without marker." >&2
  else
    echo "Snapshot marker found; proceeding with install."
  fi
fi

nixos-install --no-root-passwd --no-channel-copy --flake /root/installer#default
sync
reboot
