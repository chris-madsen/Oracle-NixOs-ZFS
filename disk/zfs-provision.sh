#!/usr/bin/env bash
set -e

# Проверка наличия bootstrap скрипта
if [ ! -f "./nixos-kexec-bootstrap.sh" ]; then
    echo "ERROR: 'nixos-kexec-bootstrap.sh' не найден."
    exit 1
fi

echo ">>> Preparing payload for injection..."
mkdir -p /root/installer

# --- 1. Disk Config (disk-config.nix) ---
cat <<EOF > /root/installer/disk-config.nix
{
  disko.devices = {
    disk = {
      main = {
        type = "disk";
        device = "/dev/sdb"; # Проверьте lsblk, если диск не sdb
        content = {
          type = "gpt";
          partitions = {
            zfs = {
              size = "100%";
              content = {
                type = "zfs";
                pool = "zroot";
              };
            };
          };
        };
      };
    };
    zpool = {
      zroot = {
        type = "zpool";
        rootFsOptions = {
          compression = "lz4";
          "com.sun:auto-snapshot" = "false";
          acltype = "posixacl";
          xattr = "sa";
          atime = "off";
          sync = "standard";
          reservation = "1G";
          mountpoint = "none";
        };
        mountpoint = null;
        options = {
          ashift = "12";
          autoexpand = "on";
          autotrim = "on";
        };
        datasets = {
          root = {
            type = "zfs_fs";
            mountpoint = "/"; 
            options.mountpoint = "legacy";
          };
          nix = {
            type = "zfs_fs";
            mountpoint = "/nix";
            options = {
              mountpoint = "legacy";
              atime = "off";
            };
          };
        };
      };
    };
  };
}
EOF

# --- 2. Installation Script (install.sh) ---
cat <<'EOF' > /root/installer/install.sh
#!/usr/bin/env bash
set -e

# Весь вывод скрипта направляем в консоль, чтобы вы видели процесс без входа по SSH
exec > /dev/console 2>&1

echo "---------------------------------------------------------"
echo ">>> [AUTO-INSTALL] Starting Automated ZFS Provisioning..."
echo "---------------------------------------------------------"

ISCSI_IQN="iqn.2015-02.oracle.boot:uefi"
ISCSI_IP="169.254.2.3"
CLIENT_INITIATOR="iqn.2024-01.com.nixos:installer"

echo ">>> [AUTO-INSTALL] 1. Setting up iSCSI..."
modprobe iscsi_tcp
mkdir -p /etc/iscsi
echo "InitiatorName=$CLIENT_INITIATOR" > /etc/iscsi/initiatorname.iscsi

# Перезапуск демона
pkill iscsid || true
iscsid

echo ">>> [AUTO-INSTALL] 2. Discovery & Login..."
# Небольшой цикл повтора, если сеть еще поднимается
for i in {1..5}; do
    if iscsiadm -m discovery -t sendtargets -p $ISCSI_IP:3260; then
        break
    fi
    echo "Discovery failed, retrying in 2s..."
    sleep 2
done

iscsiadm -m node -T $ISCSI_IQN -p $ISCSI_IP:3260 -l

echo ">>> [AUTO-INSTALL] Waiting for disk..."
sleep 5
lsblk | grep sd

echo ">>> [AUTO-INSTALL] 3. Loading ZFS module..."
modprobe zfs

echo ">>> [AUTO-INSTALL] 4. Running Disko..."
nix --extra-experimental-features "nix-command flakes" \
    run github:nix-community/disko -- --mode disko /root/installer/disk-config.nix

echo "---------------------------------------------------------"
echo ">>> [AUTO-INSTALL] SUCCESS: ZFS pool 'zroot' created and mounted."
echo ">>> You can now login via SSH and run 'nixos-generate-config --root /mnt'"
echo "---------------------------------------------------------"
EOF
chmod +x /root/installer/install.sh

# --- 3. Systemd Service (nixos-install.service) ---
cat <<EOF > /root/installer/nixos-install.service
[Unit]
Description=Automated ZFS Install via iSCSI
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/root/installer/install.sh
StandardOutput=journal+console
StandardError=journal+console

[Install]
WantedBy=multi-user.target
EOF

echo ">>> Payload created in /root/installer."
echo ">>> Launching kexec bootstrap..."

# --- 4. Launch Kexec ---
# ИСПРАВЛЕНО: Убраны аргументы. По умолчанию inject=1 и root-fstab=1.
# Это именно то, что нам нужно.
./nixos-kexec-bootstrap.sh