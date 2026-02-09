# Current State (subtask: install NixOS on iSCSI ZFS boot volume)

-## Summary
- Kernel panic is fixed.
- New compute instance was recreated via OpenTofu apply while the old one had terminated, and local helper scripts were staged/prepared.
- The temp OS remains ext4/SSH entry point (do not run `on-host-zfs-install.sh` from it directly).
- Task: make iSCSI boot volume visible in temp OS via a safe helper script, deploy ZFS on the new iSCSI boot volume (attached to the compute instance), then install NixOS on it.
- Portal info known (169.254.2.6:3260, IQN `iqn.2015-02.oracle.boot:uefi`), disk-config pins the target by PATH; installer scripts were updated but must be invoked only after safe preparation.
 - The existing data volume (100 GB) remains in place but its Terraform resources are commented out, so it won't be created or attached until later.

## Constraints
- Do not terminate or recreate the compute instance; avoid Terraform `apply` until after the new ZFS system is snapshotted.
- Temp OS (/dev/sda) must remain untouched; only modules/pkges for iSCSI can be installed.
- ZFS must be installed only on the iSCSI boot volume attached to the instance (not on temp OS).
- XFS/LVM device is out of scope until the ZFS install is done.

## Required data
- iSCSI portal/IQN (169.254.2.3:3260, `iqn.2015-02.oracle.boot:uefi`) and LUN 0 accessible from temp OS with iscsiadm.
- Snapshot ID of the new NixOS boot volume ready to be recorded in Terraform before the next apply.

## Relevant scripts (only these are in-scope)
- scripts/on-host-zfs-install.sh: loads modules, kexec loads installer (no exec), then kexec -e.
- scripts/nixos-kexec-bootstrap.sh: patches kexec params (root=fstab, rd.neednet, virtio), injects installer, dm_thin_pool in initrd.
- scripts/nixos-install.sh: runs Disko, validates zpool, then nixos-install.
- scripts/nixos-install.service: runs install.sh in installer.
- scripts/nixos-installer-run.sh: fallback to copy installer from temp OS.
- scripts/nixos-unpack-installer.sh: ungz installer payloads if needed.
- scripts/remote-zfs-install.sh: optional upload + trigger helper.

## Open issues
- Need a minimal helper script that loads `iscsi_tcp`/`scsi_transport_iscsi`, installs `iscsi-initiator-utils`, and logs into portal `169.254.2.6:3260` from temp OS without performing kexec.
- Require a new iSCSI boot volume; the existing instance’s principal boot volume was terminated unintentionally and must be replaced.
- disk-config.nix must map ZFS to the new `/dev/disk/by-path` target instead of temp OS.

- Keep the token surface minimal: only `current_state.md` is sent out; other docs stay local, and avoid unnecessary logs or chatter.
- Honor the FIX_BOOT economy rules: no browsing, use `head`/`tail -n 50` when reading logs, and do not write to `consilium_run.log`—updates happen via these docs.
- Prefer automation/infra-as-code: load modules, adjust configs, and gather iSCSI metadata through scripts before touching the instance.
- Do not reapply with Terraform until after NixOS is installed and the boot volume snapshot ID has been recorded.
