#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: remote-zfs-install.sh <host> [--user root] [--key /path/to/key] [--device /dev/sdb1] [--pool zroot]

Runs a minimal remote command over SSH that wipes the specified device and creates
a ZFS pool (with a legacy-mounted root dataset) on the iSCSI-attached volume.
USAGE
}

if [ "$#" -lt 1 ]; then
  usage >&2
  exit 2
fi

HOST="$1"
shift
USER="root"
KEY_PATH="${SSH_KEY_PATH:-$HOME/.ssh/id_rsa}"
DEVICE="/dev/sdb1"
POOL="zroot"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --user)
      shift
      USER="$1"
      ;;
    --key)
      shift
      KEY_PATH="$1"
      ;;
    --device)
      shift
      DEVICE="$1"
      ;;
    --pool)
      shift
      POOL="$1"
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Unknown arg: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

SSH_OPTS=(-i "$KEY_PATH" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5)

echo "Creating ZFS pool $POOL on $HOST:$DEVICE via SSH..."
ssh "${SSH_OPTS[@]}" "$USER@$HOST" bash -s -- "$DEVICE" "$POOL" <<'EOF'
set -euo pipefail

DEVICE="$1"
POOL="$2"

if [ "$(id -u)" -ne 0 ]; then
  echo "ERROR: This script must run as root on the target host." >&2
  exit 1
fi

if ! command -v zpool >/dev/null 2>&1; then
  echo "ERROR: zpool is not installed; install ZFS tools before running this script." >&2
  exit 1
fi

if [ ! -b "$DEVICE" ]; then
  echo "ERROR: Block device $DEVICE not found." >&2
  exit 1
fi

if zpool list -H "$POOL" >/dev/null 2>&1; then
  echo "Pool $POOL already exists; nothing to do."
  exit 0
fi

echo "Wiping existing signatures on $DEVICE..."
wipefs -af "$DEVICE"

echo "Creating ZFS pool $POOL on $DEVICE..."
zpool create -f \
  -o ashift=12 \
  -o autoexpand=on \
  -o autotrim=on \
  -O atime=off \
  -O compression=lz4 \
  -O acltype=posixacl \
  -O xattr=sa \
  -O reservation=2G \
  -O mountpoint=none \
  "$POOL" "$DEVICE"

echo "Creating legacy-mounted root dataset $POOL/root..."
zfs create -o mountpoint=legacy "$POOL/root"

echo "ZFS pool $POOL is ready."
EOF
