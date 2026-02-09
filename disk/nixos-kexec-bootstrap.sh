#!/usr/bin/env bash
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  exec sudo -E bash "$0" "$@"
fi

log_targets=(/var/log/nixos-kexec.log)
for dev in /dev/console /dev/ttyAMA0; do
  if [ -c "$dev" ] && [ -w "$dev" ]; then
    log_targets+=("$dev")
  fi
done
exec > >(tee -a "${log_targets[@]}") 2>&1

KEXEC_URL_DEFAULT="https://github.com/nix-community/nixos-images/releases/download/nixos-24.05/nixos-kexec-installer-noninteractive-aarch64-linux.tar.gz"
KEXEC_URL="${KEXEC_URL:-$KEXEC_URL_DEFAULT}"
KEXEC_NET_IFACE="${KEXEC_NET_IFACE:-enp0s6}"
KEXEC_DEBUG_SHELL="${KEXEC_DEBUG_SHELL:-1}"
WORKDIR="${KEXEC_WORKDIR:-/root/kexec}"
NO_EXEC=0
SKIP_NIX="${KEXEC_SKIP_NIX:-0}"
INJECT_INSTALLER="${KEXEC_INJECT_INSTALLER:-1}"
ADD_ROOT_FSTAB="${KEXEC_ROOT_FSTAB:-1}"
PATCH_DM_THIN="${KEXEC_PATCH_DM_THIN:-0}"

usage() {
  cat <<'USAGE'
Usage: nixos-kexec-bootstrap.sh [--no-exec] [--no-inject] [--url <tarball_url>]

Downloads a NixOS kexec installer, patches kernel params for OCI,
and runs it. By default it executes kexec (switches into installer).

Options:
  --no-exec         Patch and load, but do not execute kexec.
  --no-inject       Do not inject /root/installer into initrd.
  --root-fstab      Add root=fstab to kernel params (default: on).
  --no-root-fstab   Remove root= params from kernel params.
  --url <url>       Override kexec tarball URL.
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --no-exec) NO_EXEC=1 ;;
    --no-inject) INJECT_INSTALLER=0 ;;
    --root-fstab) ADD_ROOT_FSTAB=1 ;;
    --no-root-fstab) ADD_ROOT_FSTAB=0 ;;
    --url)
      shift
      KEXEC_URL="$1"
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

need_tools=(curl tar gzip cpio awk xz depmod)
missing=()
for tool in "${need_tools[@]}"; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    missing+=("$tool")
  fi
done

if [ "${#missing[@]}" -ne 0 ] && [ "$SKIP_NIX" != "1" ]; then
  reexec_args=()
  if [ "$NO_EXEC" -eq 1 ]; then
    reexec_args+=(--no-exec)
  fi
  if [ "$INJECT_INSTALLER" -eq 0 ]; then
    reexec_args+=(--no-inject)
  fi
  if [ "$ADD_ROOT_FSTAB" -eq 0 ]; then
    reexec_args+=(--no-root-fstab)
  fi
  export NIX_CONFIG="experimental-features = nix-command flakes"
  nix shell --extra-experimental-features "nix-command flakes" \
    nixpkgs#curl nixpkgs#gnutar nixpkgs#gzip nixpkgs#cpio nixpkgs#gawk nixpkgs#xz nixpkgs#kmod \
    -c env KEXEC_SKIP_NIX=1 KEXEC_URL="$KEXEC_URL" KEXEC_WORKDIR="$WORKDIR" \
    bash "$0" "${reexec_args[@]}"
  exit 0
fi

mkdir -p "$WORKDIR"
cd "$WORKDIR"
rm -rf kexec kexec.tar.gz

curl -fsSL "$KEXEC_URL" -o kexec.tar.gz
tar -xzf kexec.tar.gz

run_path="$WORKDIR/kexec/run"
if [ ! -f "$run_path" ]; then
  echo "kexec/run not found in tarball." >&2
  exit 1
fi

# Force legacy kexec syscall to avoid auto-detection issues on OCI.
sed -i 's/--kexec-syscall-auto/--kexec-syscall/g' "$run_path"
# Ensure kexec -e also uses the legacy syscall.
sed -i "s/' -e /' -e --kexec-syscall /" "$run_path"

patch_initrd_dm_thin() {
  if [ "$PATCH_DM_THIN" -ne 1 ]; then
    return 0
  fi

  local initrd_path="$WORKDIR/kexec/initrd"
  if [ ! -f "$initrd_path" ]; then
    echo "initrd not found at $initrd_path" >&2
    return 1
  fi

  local tmpdir
  tmpdir="$(mktemp -d)"
  local unpack_status=0
  set +e
  (cd "$tmpdir" && xz -dc "$initrd_path" | cpio -id --no-absolute-filenames)
  unpack_status=$?
  set -e
  if [ "$unpack_status" -ne 0 ] && [ "$unpack_status" -ne 141 ]; then
    echo "Failed to unpack initrd (status=$unpack_status)." >&2
    rm -rf "$tmpdir"
    return 1
  fi

  if find "$tmpdir" -type f -name 'dm-thin-pool.ko*' -o -name 'dm_thin_pool.ko*' | grep -q .; then
    rm -rf "$tmpdir"
    return 0
  fi

  local lib_link shrink_store store_root kver
  lib_link="$(readlink "$tmpdir/lib" || true)"
  if [ -z "$lib_link" ]; then
    echo "initrd lib symlink not found; cannot patch dm_thin_pool." >&2
    rm -rf "$tmpdir"
    return 1
  fi
  shrink_store="${lib_link%/lib}"
  store_root="$tmpdir$shrink_store"
  if [ ! -d "$store_root/lib/modules" ]; then
    echo "initrd modules directory not found; cannot patch dm_thin_pool." >&2
    rm -rf "$tmpdir"
    return 1
  fi
  kver="$(ls -1 "$store_root/lib/modules" | head -n1)"
  if [ -z "$kver" ]; then
    echo "initrd kernel version not found; cannot patch dm_thin_pool." >&2
    rm -rf "$tmpdir"
    return 1
  fi

  if ! command -v nix-store >/dev/null 2>&1; then
    echo "nix-store not found; cannot patch dm_thin_pool." >&2
    rm -rf "$tmpdir"
    return 1
  fi

  nix-store --realise "$shrink_store" >/dev/null 2>&1 || true
  local refs full_modules
  refs="$(nix-store --query --references "$shrink_store" 2>/dev/null || true)"
  full_modules="$(printf '%s\n' "$refs" | grep "/linux-${kver}-modules" | grep -v "modules-shrunk" | head -n1 || true)"
  if [ -z "$full_modules" ]; then
    echo "Full kernel modules not found for $kver; cannot patch dm_thin_pool." >&2
    rm -rf "$tmpdir"
    return 1
  fi

  local src_dir dst_dir
  src_dir="$full_modules/lib/modules/$kver/kernel/drivers/md"
  dst_dir="$store_root/lib/modules/$kver/kernel/drivers/md"
  mkdir -p "$dst_dir"
  cp -a "$src_dir"/dm-*.ko* "$dst_dir"/ 2>/dev/null || true

  if ! find "$dst_dir" -maxdepth 1 -type f -name 'dm-thin-pool.ko*' -o -name 'dm_thin_pool.ko*' | grep -q .; then
    echo "dm_thin_pool module still missing after copy; aborting." >&2
    rm -rf "$tmpdir"
    return 1
  fi

  depmod -b "$store_root" "$kver"

  (cd "$tmpdir" && find . | cpio -o -H newc | xz -C crc32 -T0 > "$initrd_path")
  rm -rf "$tmpdir"
}

if [ "$INJECT_INSTALLER" -eq 1 ]; then
  if [ ! -d /root/installer ]; then
    echo "Missing /root/installer. Copy payload before running." >&2
    exit 1
  fi
  if [ ! -f /root/installer/install.sh ]; then
    echo "Missing /root/installer/install.sh. Copy payload before running." >&2
    exit 1
  fi
fi

if ! patch_initrd_dm_thin; then
  echo "WARNING: dm_thin_pool patch failed; continuing without patched initrd."
fi

awk -v add_root_fstab="$ADD_ROOT_FSTAB" -v net_iface="$KEXEC_NET_IFACE" -v debug_shell="$KEXEC_DEBUG_SHELL" '
  /^kernelParams=/ {
    value = $0
    sub(/^kernelParams=/, "", value)
    if (match(value, /^"([^"]*)"([[:space:]].*)?$/, parts)) {
      value = parts[1]
      if (parts[2] != "") {
        extra = parts[2]
        sub(/^[[:space:]]+/, "", extra)
        value = value " " extra
      }
    } else {
      gsub(/^"+|"+$/, "", value)
    }
    gsub(/[[:space:]]+/, " ", value)
    sub(/^ /, "", value)
    sub(/ $/, "", value)
    if (add_root_fstab == "1") {
      gsub(/(^| )root=[^ ]+/, " ", value)
      gsub(/(^| )rootfstype=[^ ]+/, " ", value)
      gsub(/(^| )rootflags=[^ ]+/, " ", value)
      value = value " root=fstab"
    } else {
      gsub(/(^| )root=[^ ]+/, " ", value)
      gsub(/(^| )rootfstype=[^ ]+/, " ", value)
      gsub(/(^| )rootflags=[^ ]+/, " ", value)
    }
    gsub(/(^| )ip=[^ ]+/, " ", value)
    if (net_iface != "") {
      value = value " ip=:::::" net_iface ":dhcp"
    } else {
      value = value " ip=dhcp"
    }
    if (value !~ /(^| )rd.neednet=1( |$)/) value = value " rd.neednet=1"
    if (value !~ /(^| )rd.driver.pre=virtio_pci( |$)/) value = value " rd.driver.pre=virtio_pci"
    if (value !~ /(^| )rd.driver.pre=virtio_blk( |$)/) value = value " rd.driver.pre=virtio_blk"
    if (value !~ /(^| )rd.driver.pre=virtio_net( |$)/) value = value " rd.driver.pre=virtio_net"
    if (value !~ /(^| )rd.driver.pre=virtio_scsi( |$)/) value = value " rd.driver.pre=virtio_scsi"
    if (value !~ /(^| )rd.driver.pre=dm_mod( |$)/) value = value " rd.driver.pre=dm_mod"
    if (value !~ /(^| )rd.driver.pre=dm_thin_pool( |$)/) value = value " rd.driver.pre=dm_thin_pool"
    if (value !~ /(^| )systemd.log_level=/) value = value " systemd.log_level=debug"
    if (value !~ /(^| )systemd.log_target=/) value = value " systemd.log_target=console"
    if (value !~ /(^| )rd.systemd.show_status=/) value = value " rd.systemd.show_status=1"
    if (value !~ /(^| )systemd.getty_auto_login=/) value = value " systemd.getty_auto_login=root"
    if (debug_shell == "1") {
      if (value !~ /(^| )rd.shell( |$)/) value = value " rd.shell"
      if (value !~ /(^| )rd.debug( |$)/) value = value " rd.debug"
    }
    gsub(/[[:space:]]+/, " ", value)
    sub(/^ /, "", value)
    sub(/ $/, "", value)
    print "kernelParams=\"" value "\""
    next
  }
  { print }
' "$run_path" > "$run_path.tmp"
mv "$run_path.tmp" "$run_path"

if [ "$INJECT_INSTALLER" -eq 1 ]; then
  snippet_path="$WORKDIR/installer-snippet.sh"
  cat > "$snippet_path" <<'SNIPPET'
mkdir -p etc/modules-load.d
printf '%s\n' dm_mod dm_thin_pool > etc/modules-load.d/installer.conf

if [ -d /root/installer ]; then
  mkdir -p root
  cp -a /root/installer root/
  if [ -f /root/installer/nixos-install.service ]; then
    mkdir -p etc/systemd/system/multi-user.target.wants
    cp /root/installer/nixos-install.service etc/systemd/system/nixos-install.service
    ln -s /etc/systemd/system/nixos-install.service \
      etc/systemd/system/multi-user.target.wants/nixos-install.service || true
    mkdir -p etc/systemd/system/default.target.wants
    ln -s /etc/systemd/system/nixos-install.service \
      etc/systemd/system/default.target.wants/nixos-install.service || true
  fi

  # Auto-login on consoles to allow debugging via OCI console connection.
  for tty in ttyAMA0 ttyS0; do
    for unit in serial-getty getty; do
      mkdir -p "etc/systemd/system/${unit}@${tty}.service.d"
      cat > "etc/systemd/system/${unit}@${tty}.service.d/autologin.conf" <<'AUTOLOGIN'
[Service]
ExecStart=
ExecStart=-/run/current-system/sw/bin/agetty --autologin root --keep-baud 115200,38400,9600 %I $TERM
AUTOLOGIN
    done
  done

  # Debug marker to confirm injected units are loaded in the installer.
  cat > etc/systemd/system/consilium-debug.service <<'DEBUG'
[Unit]
Description=Consilium debug marker
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'echo "CONSILIUM DEBUG: systemd reached multi-user" > /dev/console'

[Install]
WantedBy=multi-user.target
DEBUG
  ln -s /etc/systemd/system/consilium-debug.service \
    etc/systemd/system/multi-user.target.wants/consilium-debug.service || true

  # Early debug marker to confirm system reached basic.target.
  cat > etc/systemd/system/consilium-debug-early.service <<'DEBUGEARLY'
[Unit]
Description=Consilium early debug marker
After=basic.target

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'echo "CONSILIUM DEBUG: systemd reached basic.target" > /dev/console'

[Install]
WantedBy=basic.target
DEBUGEARLY
  mkdir -p etc/systemd/system/basic.target.wants
  ln -s /etc/systemd/system/consilium-debug-early.service \
    etc/systemd/system/basic.target.wants/consilium-debug-early.service || true

  # Ensure DHCP config exists for any interface in the installer initrd.
  mkdir -p etc/systemd/network
  cat > etc/systemd/network/20-kexec.network <<'KEXEC_NET'
[Match]
Name=*

[Network]
DHCP=yes
KEXEC_NET

  # Allow empty root password on console (installer initrd only).
  cat > etc/systemd/system/consilium-rootpw.service <<'ROOTPW'
[Unit]
Description=Allow empty root password in installer
DefaultDependencies=no
Before=getty.target

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'if [ -f /etc/shadow ]; then sed -i \"s#^root:[^:]*:#root::#\" /etc/shadow; fi'

[Install]
WantedBy=basic.target
ROOTPW
  ln -s /etc/systemd/system/consilium-rootpw.service \
    etc/systemd/system/basic.target.wants/consilium-rootpw.service || true

  # Ensure SSH is usable in installer (keys + unit).
  if [ -f ssh/authorized_keys ]; then
    mkdir -p root/.ssh
    cp -a ssh/authorized_keys root/.ssh/authorized_keys
    chmod 700 root/.ssh
    chmod 600 root/.ssh/authorized_keys
  fi
  if ls ssh/ssh_host_* >/dev/null 2>&1; then
    mkdir -p etc/ssh
    cp -a ssh/ssh_host_* etc/ssh/ || true
  fi
  if [ ! -f etc/systemd/system/sshd.service ]; then
    cat > etc/systemd/system/sshd.service <<'SSHDUNIT'
[Unit]
Description=OpenSSH Daemon (installer)
After=network.target
Wants=network.target

[Service]
Type=simple
ExecStartPre=/bin/sh -c 'test -f /etc/ssh/ssh_host_rsa_key || (command -v ssh-keygen >/dev/null 2>&1 && ssh-keygen -A)'
ExecStart=/bin/sh -c 'exec $(command -v sshd) -D -e -f /etc/ssh/sshd_config'
Restart=on-failure

[Install]
WantedBy=multi-user.target
SSHDUNIT
  fi
  # Ensure sshd has a permissive config for key-based root login.
  mkdir -p etc/ssh
  if [ ! -f etc/ssh/sshd_config ]; then
    cat > etc/ssh/sshd_config <<'SSHD_CONFIG'
Port 22
Protocol 2
PermitRootLogin yes
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
UsePAM no
PrintMotd no
Subsystem sftp /run/current-system/sw/bin/sftp-server
AuthorizedKeysFile .ssh/authorized_keys
SSHD_CONFIG
  fi
  ln -s /etc/systemd/system/sshd.service \
    etc/systemd/system/multi-user.target.wants/sshd.service || true
  ln -s /etc/systemd/system/sshd.service \
    etc/systemd/system/default.target.wants/sshd.service || true

  # Disable firewall in installer to allow SSH.
  cat > etc/systemd/system/disable-firewall.service <<'FWUNIT'
[Unit]
Description=Disable firewall in installer
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'systemctl stop firewall.service || true; systemctl disable firewall.service || true'

[Install]
WantedBy=multi-user.target
FWUNIT
  ln -s /etc/systemd/system/disable-firewall.service \
    etc/systemd/system/multi-user.target.wants/disable-firewall.service || true
  ln -s /etc/systemd/system/disable-firewall.service \
    etc/systemd/system/default.target.wants/disable-firewall.service || true
fi
SNIPPET

  awk -v snippet="$snippet_path" '
    /find \. \| cpio -o -H newc \| gzip -9 >>/ {
      while ((getline line < snippet) > 0) print line
      close(snippet)
    }
    { print }
  ' "$run_path" > "$run_path.inject"
  mv "$run_path.inject" "$run_path"
fi

if [ "$NO_EXEC" -eq 1 ]; then
  sed -i 's/^nohup sh -c /# kexec disabled: /' "$run_path"
  sed -i 's#exec > /dev/kmsg 2>&1#:#' "$run_path"
  sed -i 's#exec > /dev/null 2>&1#:#' "$run_path"
fi

chmod +x "$run_path"
exec "$run_path"
