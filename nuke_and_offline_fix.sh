#!/bin/bash
set -e

INSTANCE="ocid1.instance.oc1.eu-stockholm-1.anqxeljr2dnu37acx4h3xk4a3b7fn3zr5gjsqzv2zcqmdexnwqc2ab3j3tmq"
COMP="ocid1.tenancy.oc1..aaaaaaaattopmnafstk26itnb7t3dqgqdprecczpuze2tdje4xuywzhoogqa"
AD="dVBP:EU-STOCKHOLM-1-AD-1"
ACTIVE_BOOT="ocid1.bootvolume.oc1.eu-stockholm-1.abqxeljrrkx2t4bjoz3romv7obsx5dffxi6qyiv6hlc3fquwetl7lrlamjwa"

echo ">>> Ensure Stopped..."
oci compute instance action --action STOP --instance-id "$INSTANCE" --wait-for-state STOPPED

echo ">>> Detaching ALL secondary boot volumes..."
# List all attachments
ALL_ATTS=$(oci compute boot-volume-attachment list --instance-id "$INSTANCE" --availability-domain "$AD" --compartment-id "$COMP" --all --output json)
ID_ATTS=$(echo "$ALL_ATTS" | jq -r ".data[] | select(.[\"boot-volume-id\"] != \"$ACTIVE_BOOT\") | .id")
if [ -n "$ID_ATTS" ]; then
  echo "$ID_ATTS" | while read att; do
    echo "Detaching attachment $att..."
    oci compute boot-volume-attachment detach --boot-volume-attachment-id "$att" --wait-for-state DETACHED || true
  done
fi

echo ">>> Nuking Orphaned Boot Volumes (Quota Fix)..."
# List ALL boot volumes in compartment/AD
ALL_BV=$(oci bv boot-volume list --compartment-id "$COMP" --availability-domain "$AD" --all --output json)
# Filter: Name contains "NixOS-Boot" or "Final" OR just ALL except ACTIVE_BOOT?
# Be safe: Filter by DisplayName pattern AND exclude Active.
TO_DELETE=$(echo "$ALL_BV" | jq -r ".data[] | select(.id != \"$ACTIVE_BOOT\") | select(.[\"display-name\"] | test(\"NixOS-Boot.*|Final|v[0-9]\")) | .id")

if [ -n "$TO_DELETE" ]; then
  echo "$TO_DELETE" | while read vol; do
    echo "Deleting Boot Volume: $vol"
    oci bv boot-volume delete --boot-volume-id "$vol" --force --wait-for-state TERMINATED || echo "Delete failed (maybe still attached?)"
  done
else
  echo "No orphaned volumes found."
fi

echo ">>> Creating v7..."
VOL_ID=$(oci bv boot-volume create --availability-domain "$AD" --compartment-id "$COMP" --source-boot-volume-id "$ACTIVE_BOOT" --size-in-gbs 50 --display-name "NixOS-Boot-v7" --wait-for-state AVAILABLE --query 'data.id' --raw-output)
echo "Created: $VOL_ID"

echo ">>> Attaching v7..."
ATTACH_ID=$(oci compute boot-volume-attachment attach --boot-volume-id "$VOL_ID" --instance-id "$INSTANCE" --wait-for-state ATTACHED --query 'data.id' --raw-output)
echo "Attached: $ATTACH_ID"

echo ">>> STARTING INSTANCE..."
oci compute instance action --action START --instance-id "$INSTANCE" --wait-for-state RUNNING

echo ">>> Waiting for SSH (120s)..."
sleep 120

echo ">>> DD..."
ssh -o StrictHostKeyChecking=no -i /home/ilja/.ssh/id_rsa root@207.127.91.190 "
  udevadm settle
  lsblk
  # Find 50G disk that is NOT sda (active), NOT sdb (ZFS src).
  # After restart, sda=TempOS. sdb=ZFS(Block). sdc=Data(Block).
  # v7 should be sdd (Boot Volume attached as secondary).
  DEST=\$(lsblk -dn -o NAME,SIZE,TYPE | grep '50G disk' | grep -v 'sda' | grep -v 'sdb' | awk '{print \$1}')
  
  if [ -z \"\$DEST\" ]; then 
     echo 'FAILURE: No disk found. LSBLK:'
     lsblk
     exit 1
  fi
  
  echo \"Target: /dev/\$DEST\"
  # Double check it is not mounted
  if mount | grep \"\$DEST\"; then echo 'Mounted! Abort'; exit 1; fi
  
  echo 'Starting Clone...'
  dd if=/dev/sdb of=/dev/\$DEST bs=4M status=progress conv=fsync
"

echo ">>> DD SUCCESS. v7 ($VOL_ID) is ready."
