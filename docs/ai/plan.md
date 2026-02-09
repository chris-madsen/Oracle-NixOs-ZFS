# Plan Options

## Step-by-step plan
- **Provision a new iSCSI boot volume.** Use OCI CLI to create a 50 GB boot block volume and attach it to `NixOS_ARM_Server` via iSCSI (without destroying the running instance).
- **Prepare temp OS for iSCSI.** Install `iscsi-initiator-utils`, load `iscsi_tcp`/`scsi_transport_iscsi`, and run `iscsiadm` discovery/login to 169.254.2.6:3260 (IQN `iqn.2015-02.oracle.boot:uefi`) using a helper script; verify `/dev/disk/by-path/...-lun-0` is present.
- **Ensure disk-config targets the iSCSI path.** Keep `disk-config.nix` pointing to `/dev/disk/by-path/ip-169.254.2.6:3260-iscsi-iqn.2015-02.oracle.boot:uefi-lun-0`, so Disko installs ZFS onto the new volume only.
- **Invoke installer safely.** After helper confirms connectivity, run `./scripts/on-host-zfs-install.sh` from temp OS; it will kexec into the installer and allow Disko + `nixos-install` to use the iSCSI volume.
- **Post-install validation.** Confirm `zpool status`, `lsblk -f`, and that `/boot` is on the new ESP. Then snapshot the boot volume, record the snapshot ID in Terraform, and only after that consider running `tofu apply`.
