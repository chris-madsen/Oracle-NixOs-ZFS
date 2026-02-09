#!/usr/bin/env bash
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  exec sudo -E bash "$0" "$@"
fi

log() { printf '%s\n' "$*"; }

os_id=""
if [ -r /etc/os-release ]; then
  . /etc/os-release
  os_id="${ID:-}"
fi

if [ "$os_id" != "nixos" ]; then
  log "Refusing to run: expected NixOS installer (ID=nixos), got '${os_id:-unknown}'"
  exit 1
fi

if [ ! -x /root/installer/install.sh ]; then
  log "Installer payload not found, mounting /dev/sda1..."
  mkdir -p /mnt/ubuntu

  mounted=0
  if ! awk '$2=="/mnt/ubuntu" {found=1} END{exit found?0:1}' /proc/mounts; then
    if [ ! -b /dev/sda1 ]; then
      log "ERROR: /dev/sda1 not found."
      exit 1
    fi
    mount /dev/sda1 /mnt/ubuntu
    mounted=1
  fi

  if [ ! -d /mnt/ubuntu/root/installer ]; then
    log "ERROR: /mnt/ubuntu/root/installer not found."
    exit 1
  fi

  cp -a /mnt/ubuntu/root/installer /root/

  if [ "$mounted" -eq 1 ]; then
    umount /mnt/ubuntu
  fi
fi

if [ -x /usr/local/bin/nixos-unpack-installer.sh ]; then
  /usr/local/bin/nixos-unpack-installer.sh || true
fi

exec /root/installer/install.sh
