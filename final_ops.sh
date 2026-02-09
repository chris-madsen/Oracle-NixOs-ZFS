#!/bin/bash
set -e

INSTANCE="ocid1.instance.oc1.eu-stockholm-1.anqxeljr2dnu37acx4h3xk4a3b7fn3zr5gjsqzv2zcqmdexnwqc2ab3j3tmq"
COMP="ocid1.tenancy.oc1..aaaaaaaattopmnafstk26itnb7t3dqgqdprecczpuze2tdje4xuywzhoogqa"
AD="dVBP:EU-STOCKHOLM-1-AD-1"
# Source TempOS Boot Volume ID (Active)
SRC_BOOT="ocid1.bootvolume.oc1.eu-stockholm-1.abqxeljrrkx2t4bjoz3romv7obsx5dffxi6qyiv6hlc3fquwetl7lrlamjwa"

echo ">>> Creating Target Boot Volume (Final Clone)..."
VOL_ID=$(oci bv boot-volume create --availability-domain "$AD" --compartment-id "$COMP" --source-boot-volume-id "$SRC_BOOT" --size-in-gbs 50 --display-name "NixOS-ZFS-Actual-Boot" --wait-for-state AVAILABLE --query 'data.id' --raw-output)
echo "Created: $VOL_ID"

echo ">>> Attaching Target..."
ATTACH_ID=$(oci compute boot-volume-attachment attach --boot-volume-id "$VOL_ID" --instance-id "$INSTANCE" --wait-for-state ATTACHED --query 'data.id' --raw-output)
echo "Attached: $ATTACH_ID"

echo ">>> Remote DD..."
ssh -o StrictHostKeyChecking=no -i /home/ilja/.ssh/id_rsa root@207.127.91.190 "
  udevadm settle
  lsblk
  # Identify disks.
  # sda = Current Boot (50G)
  # sdb = ZFS Source (50G)
  # sdc = New Target (50G)? (Since data volume removed)
  
  # Heuristic: Target is the one that is NOT sda and NOT sdb (assuming sdb is the ZFS signature one).
  # Check ZFS signature on sdb just in case.
  # But user said /dev/oracleoci/oraclevdb is attached. That maps to sdb usually.
  
  SRC_DEV=\$(lsblk -o NAME,FSTYPE,SIZE -rn | grep zfs_member | awk '{print \$1}' | sed 's/[0-9]*$//' | head -n 1)
  if [ -z \"\$SRC_DEV\" ]; then 
     echo 'Warning: lsblk did not find zfs_member. Checking /dev/sdb...'
     SRC_DEV='sdb'
  fi
  
  TARGET_DEV=\$(lsblk -dn -o NAME,SIZE,TYPE | grep '50G disk' | grep -v 'sda' | grep -v \"\$SRC_DEV\" | awk '{print \$1}')
  
  if [ -z \"\$TARGET_DEV\" ]; then echo 'FAILURE: Target disk not found!'; exit 1; fi
  
  echo \"Source: /dev/\$SRC_DEV\"
  echo \"Target: /dev/\$TARGET_DEV\"
  
  dd if=/dev/\$SRC_DEV of=/dev/\$TARGET_DEV bs=4M status=progress conv=fsync
"

echo ">>> Detaching Target..."
oci compute boot-volume-attachment detach --boot-volume-attachment-id "$ATTACH_ID" --wait-for-state DETACHED

echo ">>> SUCCESS. New Volume ready for Switch: $VOL_ID"
