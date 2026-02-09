#!/usr/bin/env bash
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  exec sudo -E bash "$0" "$@"
fi

INJECT=0
FORCE=0
AUTO=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --inject) INJECT=1 ;;
    --no-inject) INJECT=0 ;;
    --force) FORCE=1 ;;
    --auto) AUTO=1 ;;
    --help|-h)
      echo "Usage: $0 [--inject|--no-inject] [--force] [--auto]"
      exit 0
      ;;
    *)
      echo "Unknown arg: $1"
      exit 2
      ;;
  esac
  shift
done

log() { printf '%s\n' "$*"; }

if [ -x /usr/local/bin/nixos-unpack-installer.sh ]; then
  /usr/local/bin/nixos-unpack-installer.sh || true
fi

log "== Preflight =="
if command -v cloud-init >/dev/null 2>&1; then
  cloud-init status --long || true
fi
ls -l /var/lib/cloud/instance/boot-finished || true

if [ ! -x /usr/local/bin/nixos-autotest.sh ]; then
  log "ERROR: /usr/local/bin/nixos-autotest.sh not found."
  exit 1
fi

if ! /usr/local/bin/nixos-autotest.sh; then
  if [ "$FORCE" -ne 1 ]; then
    log "Autotests failed. Re-run with --force to continue anyway."
    exit 1
  fi
fi

if ! grep -q "networking.hostId" /root/installer/configuration.nix 2>/dev/null && \
   ! grep -q "networking.hostId" /root/installer/configuration.minimal.nix 2>/dev/null; then
  log "ERROR: networking.hostId missing in /root/installer/configuration.nix or configuration.minimal.nix."
  exit 1
fi

log "== Kexec load =="
if [ "$INJECT" -eq 1 ]; then
  KEXEC_INJECT_INSTALLER=1 KEXEC_MODE=load /root/installer/bootstrap-kexec.sh
else
  KEXEC_INJECT_INSTALLER=0 KEXEC_MODE=load /root/installer/bootstrap-kexec.sh
fi

if [ "$(cat /sys/kernel/kexec_loaded 2>/dev/null || echo 0)" != "1" ]; then
  log "ERROR: kexec not loaded."
  exit 1
fi

log "Ready to switch into NixOS installer."
if [ "$INJECT" -eq 0 ]; then
  log "Note: running without inject. In installer run:"
  if [ -x /root/installer/nixos-installer-from-installer.sh ]; then
    log "  mkdir -p /mnt/ubuntu && mount /dev/sda1 /mnt/ubuntu && bash /mnt/ubuntu/root/installer/nixos-installer-from-installer.sh"
  else
    log "  mkdir -p /mnt/ubuntu && mount /dev/sda1 /mnt/ubuntu && bash /mnt/ubuntu/root/installer/nixos-installer-run.sh"
  fi
  log "Minimal path (no Disko/ZFS/LVM):"
  log "  mkdir -p /mnt/ubuntu && mount /dev/sda1 /mnt/ubuntu && bash /mnt/ubuntu/root/installer/nixos-minimal-install.sh"
fi
if [ "$AUTO" -eq 1 ]; then
  log "Auto handoff enabled. Switching via kexec now."
  kexec -e
fi

log "Auto handoff disabled. Run 'kexec -e' when ready."
