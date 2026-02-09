#!/bin/bash
set -e

INSTANCE="ocid1.instance.oc1.eu-stockholm-1.anqxeljr2dnu37acx4h3xk4a3b7fn3zr5gjsqzv2zcqmdexnwqc2ab3j3tmq"
COMP="ocid1.tenancy.oc1..aaaaaaaattopmnafstk26itnb7t3dqgqdprecczpuze2tdje4xuywzhoogqa"
AD="dVBP:EU-STOCKHOLM-1-AD-1"
# v7 from prev step
VOL_ID="ocid1.bootvolume.oc1.eu-stockholm-1.abqxeljrj2tq2cz7t6cko4q3tvh6k3gtvspkmc5dojsf4wx6ponyeu4u6aia"

echo ">>> Checking v7 status..."
STATE=$(oci bv boot-volume get --boot-volume-id "$VOL_ID" --query 'data."lifecycle-state"' --raw-output)
echo "v7 is $STATE"

if [ "$STATE" != "AVAILABLE" ]; then
  echo "v7 failed/busy. Creating v8..."
  SRC_BOOT="ocid1.bootvolume.oc1.eu-stockholm-1.abqxeljrrkx2t4bjoz3romv7obsx5dffxi6qyiv6hlc3fquwetl7lrlamjwa"
  VOL_ID=$(oci bv boot-volume create --availability-domain "$AD" --compartment-id "$COMP" --source-boot-volume-id "$SRC_BOOT" --size-in-gbs 50 --display-name "NixOS-Boot-v8" --wait-for-state AVAILABLE --query 'data.id' --raw-output)
  echo "Created v8: $VOL_ID"
fi

echo ">>> Attaching Target Volume..."
ATTACH_ID=$(oci compute boot-volume-attachment attach --boot-volume-id "$VOL_ID" --instance-id "$INSTANCE" --wait-for-state ATTACHED --query 'data.id' --raw-output)
echo "Attached: $ATTACH_ID"

echo ">>> STARTING INSTANCE..."
oci compute instance action --action START --instance-id "$INSTANCE" --wait-for-state RUNNING

echo ">>> Waiting for SSH (60s)..."
sleep 60

echo ">>> Attaching Source ZFS (sdb) again?..."
# Wait, user detached Block Volumes??
# Screenshot shows "data-volume" attached.
# DID USER DETACH "boot-volume" (the Block Vol with ZFS)??
# Screenshot shows "Applied filters: Attach block volume".
# Only "data-volume" is visible in list.
# 
# CRITICAL CHECK: Is the source ZFS volume attached?
# If not, I attach it.
ZFS_BLOCK_ID="ocid1.volume.oc1.eu-stockholm-1.abqxeljrwvwjvvaxm6zahbziygh7mlltsg7ewjtqtwxls3gjiwvuqqzvyoqa"
# (ID from earlier logs)

CHECK_ZFS=$(oci compute volume-attachment list --instance-id "$INSTANCE" --all --output json | jq -r ".data[] | select(.[\"volume-id\"] == \"$ZFS_BLOCK_ID\") | .id")

if [ -z "$CHECK_ZFS" ]; then
  echo "ZFS source detached! Re-attaching..."
  oci compute volume-attachment attach --volume-id "$ZFS_BLOCK_ID" --instance-id "$INSTANCE" --type paravirtualized --wait-for-state ATTACHED
else
  echo "ZFS source present."
fi

echo ">>> DD..."
ssh -o StrictHostKeyChecking=no -i /home/ilja/.ssh/id_rsa root@207.127.91.190 "
  udevadm settle
  lsblk -o NAME,SIZE,TYPE,MODEL
  
  # Logic:
  # sda = Current Boot (50G)
  # sdb/c/d?
  # We have:
  # 1. ZFS Source Block Vol (50G).
  # 2. Target Boot Vol (50G).
  # 3. Data Vol (100G).
  
  # Find Source (ZFS one). It has 'zroot' partition? No, it has partitions sdb1/sdb2.
  # We can check by PARTLABEL or size.
  # But we need to distinguish Source vs Target (both 50G).
  # Target is FRESH CLONE of TempOS. So it has ext4 label 'nixos-root'.
  # Source is ZFS.
  
  SRC_DEV=\$(lsblk -o NAME,FSTYPE -rn | grep zfs_member | awk '{print \$1}' | sed 's/[0-9]*$//' | head -n 1) # e.g. sdb from sdb2
  if [ -z \"\$SRC_DEV\" ]; then echo 'ZFS Source not found via lsblk signature!'; lsblk -f; exit 1; fi
  
  # Target is the OTHER 50G disk that is NOT sda and NOT SRC.
  TARGET_DEV=\$(lsblk -dn -o NAME,SIZE,TYPE | grep '50G disk' | grep -v 'sda' | grep -v \"\$SRC_DEV\" | awk '{print \$1}')
  
  if [ -z \"\$TARGET_DEV\" ]; then echo 'Target disk not found!'; exit 1; fi
  
  echo \"Source: /dev/\$SRC_DEV (ZFS)\"
  echo \"Target: /dev/\$TARGET_DEV (Clone)\"
  
  echo 'Starting Clone...'
  dd if=/dev/\$SRC_DEV of=/dev/\$TARGET_DEV bs=4M status=progress conv=fsync
"

echo ">>> Detaching Target Volume..."
oci compute boot-volume-attachment detach --boot-volume-attachment-id "$ATTACH_ID" --wait-for-state DETACHED

echo ">>> SUCCESS. READY TO SWITCH."
echo "Use Boot Volume ID: $VOL_ID"
