#!/usr/bin/env bash
set -e
if [ -z "$1" ]; then echo "Usage: $0 <HOST> [KEY]"; exit 1; fi
HOST="$1"
SSH_KEY="${2:-$HOME/.ssh/id_rsa}"

# 2. Заливаем
ssh -o StrictHostKeyChecking=no -i "$SSH_KEY" "root@$HOST" "mkdir -p /root/installer"
scp -o StrictHostKeyChecking=no -i "$SSH_KEY" configuration.nix disk-config.nix install.sh nixos-install.service flake.nix trigger_kexec.sh iscsi_install_master.sh "root@$HOST:/root/installer/"
scp -o StrictHostKeyChecking=no -i "$SSH_KEY" nixos-kexec-bootstrap.sh "root@$HOST:/root/"
ssh -o StrictHostKeyChecking=no -i "$SSH_KEY" "root@$HOST" "chmod +x /root/installer/install.sh /root/installer/trigger_kexec.sh /root/installer/iscsi_install_master.sh /root/nixos-kexec-bootstrap.sh"

echo "ГОТОВО. Запускай на сервере: /root/installer/trigger_kexec.sh"
