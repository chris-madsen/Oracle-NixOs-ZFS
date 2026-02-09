# Errors and Problems

- Kernel panic is fixed; new blocker is iSCSI boot volume not visible in temp OS.
- Temp OS is the only SSH entry point; any change that breaks SSH blocks progress.
- iSCSI modules/initiator may be missing in temp OS (iscsi_tcp, libiscsi, libiscsi_tcp, scsi_transport_iscsi).
- Device path for iSCSI boot volume not pinned; /dev/sdX may change across boots.
- ZFS must be created on the iSCSI-attached boot volume (50GB); current Disko config assumes /dev/sdb.
- XFS/LVM device is not attached yet; must not be touched in this phase.
