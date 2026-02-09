#!/usr/bin/env bash
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  exec sudo -E bash "$0" "$@"
fi

os_id=""
if [ -r /etc/os-release ]; then
  . /etc/os-release
  os_id="${ID:-}"
fi
if [ "$os_id" != "nixos" ]; then
  echo "Refusing to run: expected NixOS installer (ID=nixos), got '${os_id:-unknown}'"
  exit 1
fi

ROOT_DEV="/dev/sda1"
ESP_DEV="/dev/sda15"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_SRC="$SCRIPT_DIR/configuration.minimal.nix"
if [ ! -f "$CONFIG_SRC" ] && [ -f /root/installer/configuration.minimal.nix ]; then
  CONFIG_SRC="/root/installer/configuration.minimal.nix"
fi
if [ -n "${NIXOS_MINIMAL_CONFIG:-}" ]; then
  CONFIG_SRC="$NIXOS_MINIMAL_CONFIG"
fi

if [ ! -b "$ROOT_DEV" ]; then
  echo "ERROR: $ROOT_DEV not found." >&2
  exit 1
fi
if [ ! -b "$ESP_DEV" ]; then
  echo "ERROR: $ESP_DEV not found." >&2
  exit 1
fi
if [ ! -f "$CONFIG_SRC" ]; then
  echo "ERROR: $CONFIG_SRC not found." >&2
  exit 1
fi

if findmnt -n -o SOURCE /mnt/ubuntu 2>/dev/null | grep -qx "$ROOT_DEV"; then
  cfg_tmp="/tmp/configuration.minimal.nix"
  if [ -f "$CONFIG_SRC" ]; then
    cp -a "$CONFIG_SRC" "$cfg_tmp"
    export NIXOS_MINIMAL_CONFIG="$cfg_tmp"
  fi
  tmp="/tmp/nixos-minimal-install.sh"
  self="${BASH_SOURCE[0]:-$0}"
  cp -a "$self" "$tmp"
  chmod +x "$tmp"
  umount /mnt/ubuntu
  exec "$tmp" "$@"
fi

umount /mnt/boot >/dev/null 2>&1 || true
umount /mnt >/dev/null 2>&1 || true

mkfs.ext4 -F -L nixos-root "$ROOT_DEV"

mkdir -p /mnt
mount "$ROOT_DEV" /mnt
mkdir -p /mnt/boot
mount "$ESP_DEV" /mnt/boot

nixos-generate-config --root /mnt

cfg_tmp="$(mktemp)"
magic="$(od -An -tx1 -N2 "$CONFIG_SRC" | tr -d ' \n')"
if [ "$magic" = "1f8b" ]; then
  gzip -dc "$CONFIG_SRC" > "$cfg_tmp"
else
  cp -a "$CONFIG_SRC" "$cfg_tmp"
fi
mkdir -p /mnt/etc/nixos
cp -a "$cfg_tmp" /mnt/etc/nixos/configuration.nix
rm -f "$cfg_tmp"

detect_nixpkgs() {
  local candidate=""
  for candidate in \
    /nix/var/nix/profiles/per-user/root/channels/nixos \
    /nix/var/nix/profiles/system/sw/share/nixpkgs; do
    if [ -d "$candidate" ]; then
      echo "$candidate"
      return 0
    fi
  done
  return 1
}

nixpkgs_path="$(detect_nixpkgs || true)"
if [ -z "$nixpkgs_path" ]; then
  nixpkgs_ver="nixos-24.11"
  nixpkgs_dir="/tmp/$nixpkgs_ver"
  if [ ! -d "$nixpkgs_dir" ]; then
    curl -fsSL "https://github.com/NixOS/nixpkgs/archive/$nixpkgs_ver.tar.gz" \
      | tar -xz -C /tmp
    mv "/tmp/nixpkgs-$nixpkgs_ver" "$nixpkgs_dir"
  fi
  nixpkgs_path="$nixpkgs_dir"
fi

NIX_PATH="nixpkgs=$nixpkgs_path" nixos-install --no-root-passwd --no-channel-copy -I "nixpkgs=$nixpkgs_path"
sync
reboot
