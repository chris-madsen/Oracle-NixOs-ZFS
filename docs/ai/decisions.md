# Decisions (current)

- Kernel panic resolved; the priority is to prepare a safe iSCSI helper for temp OS and install ZFS on a newly created iSCSI boot volume without recreating the instance.
- Temp OS is a read-only staging environment now; no `tofu apply` or Terraform edits until the new iSCSI boot volume is installed and snapshotted.
- Use only minimal helper scripts on temp OS to load iSCSI modules and `iscsiadm`. Run `on-host-zfs-install.sh` only after the helper confirms the by-path device is visible.
- Pin the boot volume to `/dev/disk/by-path/ip-169.254.2.6:3260-iscsi-iqn.2015-02.oracle.boot:uefi-lun-0`, and once NixOS installs, snapshot that volume and record its ID in Terraform before touching apply again.
