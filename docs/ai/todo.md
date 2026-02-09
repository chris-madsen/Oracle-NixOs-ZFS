# Todo (Oracle free)

- Keep temp OS (ext4 on /dev/sda) untouched; work only from it now to configure iSCSI connectivity without triggering kexec.
- Create and attach a fresh 50 GB block volume (Boot Volume) to `NixOS_ARM_Server` via OCI CLI so it can be consumed over iSCSI.
- Develop a minimal helper script for temp OS that installs `iscsi-initiator-utils`, loads `iscsi_tcp`/`scsi_transport_iscsi`, runs `iscsiadm` discovery/login to portal 169.254.2.6:3260 with IQN `iqn.2015-02.oracle.boot:uefi`, and confirms `/dev/disk/by-path/...-lun-0` exists.
- Keep `disk-config.nix` pointed at `/dev/disk/by-path/ip-169.254.2.6:3260-iscsi-iqn.2015-02.oracle.boot:uefi-lun-0` so Disko writes ZFS to the new volume.
- Only after the helper verifies the iSCSI volume is reachable run `./scripts/on-host-zfs-install.sh` from temp OS; Disko then installs ZFS on that iSCSI volume, not on temp OS.
- Once the new NixOS install is successful, record the boot volume’s snapshot ID and update Terraform before any future `tofu apply`.
