#!/usr/bin/env bash
set -euo pipefail

unpack_if_gzip() {
  local path="$1"
  local magic=""
  if [ ! -f "$path" ]; then
    return 0
  fi
  magic="$(od -An -tx1 -N2 "$path" | tr -d ' \n')"
  if [ "$magic" = "1f8b" ]; then
    mv "$path" "$path.gz"
    gzip -dc "$path.gz" > "$path"
    rm -f "$path.gz"
    chmod 0644 "$path" || true
  fi
}

unpack_if_gzip /root/installer/flake.nix
unpack_if_gzip /root/installer/configuration.nix
unpack_if_gzip /root/installer/configuration.minimal.nix
unpack_if_gzip /root/installer/disk-config.nix
