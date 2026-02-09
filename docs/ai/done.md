# Done

- Kernel panic fixed; kexec flow already patches root=fstab, rd.neednet, virtio, dm-thin params.
- Temp OS (ext4 on `/dev/sda`) stays as the SSH entry point; a new compute instance (id `ocid1.instance...acckum4k...`) was provisioned via `tofu apply` while keeping SSH alive.
- A helper script now loads iSCSI transport modules (`prepare-iscsi-helper.sh`) and ensures the boot volume is discovered safely, leaving `on-host-zfs-install.sh` ready for use once the helper confirms connectivity.
