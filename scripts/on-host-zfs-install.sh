#!/usr/bin/env bash
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  exec sudo -E bash "$0" "$@"
fi

log_targets=(/root/installer/on-host-zfs-install.log)
for dev in /dev/console /dev/ttyAMA0; do
  if [ -c "$dev" ] && [ -w "$dev" ]; then
    log_targets+=("$dev")
  fi
done
exec > >(tee -a "${log_targets[@]}") 2>&1

if [ ! -d /root/installer ]; then
  echo "ERROR: /root/installer not found. Upload payload first." >&2
  exit 1
fi

if [ ! -x /root/installer/nixos-kexec-bootstrap.sh ]; then
  echo "ERROR: /root/installer/nixos-kexec-bootstrap.sh not found or not executable." >&2
  exit 1
fi
if ! grep -q "KEXEC_ROOT_FSTAB" /root/installer/nixos-kexec-bootstrap.sh; then
  echo "ERROR: /root/installer/nixos-kexec-bootstrap.sh is outdated; re-upload installer payload." >&2
  exit 1
fi

if [ ! -f /root/installer/install.sh ]; then
  if [ -f /root/installer/nixos-install.sh ]; then
    cp /root/installer/nixos-install.sh /root/installer/install.sh
  else
    echo "ERROR: /root/installer/install.sh missing and no nixos-install.sh fallback." >&2
    exit 1
  fi
fi

chmod +x /root/installer/*.sh /root/installer/install.sh || true
touch /root/installer/ENABLE_NIXOS_INSTALL

# Load required kernel modules with dynamic kernel version detection
echo "Loading required kernel modules..."
KERNEL_VERSION=$(uname -r)
echo "Detected kernel version: $KERNEL_VERSION"

# Function to load a module with fallback handling
load_module_with_fallback() {
  local module_name="$1"
  local description="$2"
  
  echo "Attempting to load $module_name module ($description)..."
  
  # First try: Check if module exists for current kernel
  if modinfo "$module_name" >/dev/null 2>&1; then
    if modprobe "$module_name" 2>/dev/null; then
      echo "Successfully loaded $module_name module."
      return 0
    else
      echo "WARNING: $module_name module found but failed to load."
    fi
  else
    echo "WARNING: $module_name module not found for kernel $KERNEL_VERSION."
  fi
  
  # Second try: Look for module in alternative kernel module paths
  local module_paths=(
    "/lib/modules/$KERNEL_VERSION/kernel/drivers/md/$module_name.ko"
    "/lib/modules/$KERNEL_VERSION/extra/$module_name.ko"
    "/lib/modules/$KERNEL_VERSION/**/$module_name.ko"
  )
  
  for path in "${module_paths[@]}"; do
    if [ -f "$path" ]; then
      echo "Found $module_name at $path, attempting manual load..."
      if insmod "$path" 2>/dev/null; then
        echo "Successfully loaded $module_name module via insmod."
        return 0
      fi
    fi
  done
  
  # Third try: Check if module is already loaded
  if lsmod | grep -q "^$module_name "; then
    echo "$module_name module is already loaded."
    return 0
  fi
  
  echo "WARNING: Could not load $module_name module. $description may not work properly."
  return 1
}

# Load dm_thin_pool module (needed for ZFS thin provisioning)
load_module_with_fallback "dm_thin_pool" "ZFS thin provisioning"

# Load other potentially useful modules for ZFS
load_module_with_fallback "dm_mod" "Device mapper support"
load_module_with_fallback "zfs" "ZFS filesystem support" || true

# Load iSCSI transport modules before probing targets
load_module_with_fallback "iscsi_tcp" "iSCSI TCP transport"
load_module_with_fallback "scsi_transport_iscsi" "SCSI iSCSI transport"

ISCSI_PORTAL="${ISCSI_PORTAL:-169.254.2.3}"
ISCSI_PORT="${ISCSI_PORT:-3260}"
ISCSI_IQN="${ISCSI_IQN:-iqn.2015-02.oracle.boot:uefi}"
ISCSI_LUN="${ISCSI_LUN:-0}"

ensure_iscsi_session() {
  if ! command -v iscsiadm >/dev/null 2>&1; then
    echo "ERROR: iscsiadm not installed; cannot reach iSCSI boot target." >&2
    return 1
  fi

  existing=$(iscsiadm -m session 2>/dev/null || true)
  if echo "$existing" | grep -q "$ISCSI_IQN"; then
    echo "iSCSI session for $ISCSI_IQN already active."
    return 0
  fi

  echo "Discovering iSCSI target $ISCSI_IQN at $ISCSI_PORTAL:$ISCSI_PORT..."
  if ! iscsiadm -m discovery -t sendtargets -p "${ISCSI_PORTAL}:${ISCSI_PORT}"; then
    echo "ERROR: Target discovery failed for $ISCSI_PORTAL:$ISCSI_PORT" >&2
    return 1
  fi

  echo "Logging into iSCSI target $ISCSI_IQN..."
  iscsiadm -m node -T "$ISCSI_IQN" -p "${ISCSI_PORTAL}:${ISCSI_PORT}" --op update -n node.startup -v automatic || true
  iscsiadm -m node -T "$ISCSI_IQN" -p "${ISCSI_PORTAL}:${ISCSI_PORT}" -l
}

if ! ensure_iscsi_session; then
  echo "ERROR: Could not establish iSCSI connection to portal $ISCSI_PORTAL." >&2
  exit 1
fi

echo "Starting kexec bootstrap (SSH will drop)..."
# Ensure root=fstab is preserved; required for kexec installer to mount its root.
export KEXEC_ROOT_FSTAB="${KEXEC_ROOT_FSTAB:-1}"
/root/installer/nixos-kexec-bootstrap.sh --no-exec "$@"

if [ "$(cat /sys/kernel/kexec_loaded 2>/dev/null || echo 0)" != "1" ]; then
  echo "ERROR: kexec image not loaded; aborting." >&2
  exit 1
fi

echo "Kexec image loaded. Switching via direct kexec -e (no firmware reboot)..."
if [ -x /root/kexec/kexec/kexec ]; then
  /root/kexec/kexec/kexec -e
else
  kexec -e
fi
