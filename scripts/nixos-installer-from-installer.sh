#!/usr/bin/env bash
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  exec sudo -E bash "$0" "$@"
fi

if [ ! -b /dev/sda1 ]; then
  echo "ERROR: /dev/sda1 not found." >&2
  exit 1
fi

mkdir -p /mnt/ubuntu
if ! awk '$2=="/mnt/ubuntu" {found=1} END{exit found?0:1}' /proc/mounts; then
  mount /dev/sda1 /mnt/ubuntu
fi

exec /mnt/ubuntu/root/installer/nixos-installer-run.sh
