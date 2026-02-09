#!/bin/bash
set -e

INSTANCE="ocid1.instance.oc1.eu-stockholm-1.anqxeljr2dnu37acx4h3xk4a3b7fn3zr5gjsqzv2zcqmdexnwqc2ab3j3tmq"
COMP="ocid1.tenancy.oc1..aaaaaaaattopmnafstk26itnb7t3dqgqdprecczpuze2tdje4xuywzhoogqa"
AD="dVBP:EU-STOCKHOLM-1-AD-1"
ACTIVE_BOOT="ocid1.bootvolume.oc1.eu-stockholm-1.abqxeljrrkx2t4bjoz3romv7obsx5dffxi6qyiv6hlc3fquwetl7lrlamjwa"
ZFS_BLOCK_ID="ocid1.volume.oc1.eu-stockholm-1.abqxeljrwvwjvvaxm6zahbziygh7mlltsg7ewjtqtwxls3gjiwvuqqzvyoqa"

echo ">>> Cleaning v7..."
VOL_V7="ocid1.bootvolume.oc1.eu-stockholm-1.abqxeljrj2tq2cz7t6cko4q3tvh6k3gtvspkmc5dojsf4wx6ponyeu4u6aia"
oci bv boot-volume delete --boot-volume-id "$VOL_V7" --force || true

echo ">>> Creating v8..."
VOL_ID=$(oci bv boot-volume create --availability-domain "$AD" --compartment-id "$COMP" --source-boot-volume-id "$ACTIVE_BOOT" --size-in-gbs 50 --display-name "NixOS-Boot-v8" --wait-for-state AVAILABLE --query 'data.id' --raw-output)
echo "Created: $VOL_ID"

echo ">>> Checking ZFS Source..."
CHECK_ZFS=$(oci compute volume-attachment list --instance-id "$INSTANCE" --all --output json | jq -r ".data[] | select(.[\"volume-id\"] == \"$ZFS_BLOCK_ID\") | .id")
if [ -z "$CHECK_ZFS" ]; then
  echo "Attaching ZFS Source..."
  oci compute volume-attachment attach --volume-id "$ZFS_BLOCK_ID" --instance-id "$INSTANCE" --type paravirtualized --wait-for-state ATTACHED
fi

echo ">>> Attaching Target v8..."
# Retry logic for attachment?
ATTACH_ID=$(oci compute boot-volume-attachment attach --boot-volume-id "$VOL_ID" --instance-id "$INSTANCE" --wait-for-state ATTACHED --query 'data.id' --raw-output)
echo "Attached: $ATTACH_ID"

echo ">>> STARTING..."
oci compute instance action --action START --instance-id "$INSTANCE" --wait-for-state RUNNING

echo ">>> Waiting SSH..."
sleep 60

echo ">>> DD..."
ssh -o StrictHostKeyChecking=no -i /home/ilja/.ssh/id_rsa root@207.127.91.190 "
  udevadm settle
  SRC_DEV=\$(lsblk -o NAME,FSTYPE -rn | grep zfs_member | awk '{print \$1}' | sed 's/[0-9]*$//' | head -n 1)
  if [ -z \"\$SRC_DEV\" ]; then echo 'No ZFS source!'; lsblk; exit 1; fi
  
  TARGET_DEV=\$(lsblk -dn -o NAME,SIZE,TYPE | grep '50G disk' | grep -v 'sda' | grep -v \"\$SRC_DEV\" | awk '{print \$1}')
  
  echo \"Cloning /dev/\$SRC_DEV to /dev/\$TARGET_DEV...\"
  dd if=/dev/\$SRC_DEV of=/dev/\$TARGET_DEV bs=4M status=progress conv=fsync
"

echo ">>> Detaching v8..."
oci compute boot-volume-attachment detach --boot-volume-attachment-id "$ATTACH_ID" --wait-for-state DETACHED

echo "SUCCESS. Boot Volume ID: $VOL_ID"
