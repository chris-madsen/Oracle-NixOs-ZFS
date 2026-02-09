#!/bin/bash
set -e

INSTANCE="ocid1.instance.oc1.eu-stockholm-1.anqxeljr2dnu37acx4h3xk4a3b7fn3zr5gjsqzv2zcqmdexnwqc2ab3j3tmq"
COMP="ocid1.tenancy.oc1..aaaaaaaattopmnafstk26itnb7t3dqgqdprecczpuze2tdje4xuywzhoogqa"
AD="dVBP:EU-STOCKHOLM-1-AD-1"
ACTIVE_BOOT="ocid1.bootvolume.oc1.eu-stockholm-1.abqxeljrrkx2t4bjoz3romv7obsx5dffxi6qyiv6hlc3fquwetl7lrlamjwa"

echo ">>> STOPPING INSTANCE..."
oci compute instance action --action STOP --instance-id "$INSTANCE" --wait-for-state STOPPED

echo ">>> Pruning Attachments on Stopped Instance..."
# List all attachments
ALL_ATTS=$(oci compute boot-volume-attachment list --instance-id "$INSTANCE" --availability-domain "$AD" --compartment-id "$COMP" --all --output json)
# Filter out Active Boot
IDS_TO_DETACH=$(echo "$ALL_ATTS" | jq -r ".data[] | select(.[\"boot-volume-id\"] != \"$ACTIVE_BOOT\") | .id")

if [ -n "$IDS_TO_DETACH" ]; then
  echo "$IDS_TO_DETACH" | while read att_id; do
    echo "Detaching $att_id..."
    oci compute boot-volume-attachment detach --boot-volume-attachment-id "$att_id" --wait-for-state DETACHED
  done
else
  echo "Clean."
fi

echo ">>> Creating Boot Volume v6..."
# Source from ACTIVE_BOOT (TempOS)
VOL_ID=$(oci bv boot-volume create --availability-domain "$AD" --compartment-id "$COMP" --source-boot-volume-id "$ACTIVE_BOOT" --size-in-gbs 50 --display-name "NixOS-Boot-v6" --wait-for-state AVAILABLE --query 'data.id' --raw-output)
echo "Created v6: $VOL_ID"

echo ">>> Attaching v6 to STOPPED instance..."
# Only one boot volume can be attached as 'boot volume'.
# But we can attach a boot volume as a generic volume?
# 'oci compute boot-volume-attachment attach' adds it to the list.
# Is there a flag for "secondary"? No.
# OCI allows multiple boot volumes attached. The one with "bootVolume" relationship logic (lowest index?) boots?
# Usually index 0 is boot.
ATTACH_ID=$(oci compute boot-volume-attachment attach --boot-volume-id "$VOL_ID" --instance-id "$INSTANCE" --wait-for-state ATTACHED --query 'data.id' --raw-output)
echo "Attached v6: $ATTACH_ID"

echo ">>> STARTING INSTANCE..."
oci compute instance action --action START --instance-id "$INSTANCE" --wait-for-state RUNNING

echo ">>> Waiting for SSH..."
# Wait loop logic (simplified)
sleep 60

echo ">>> DD..."
# sda = Active Boot.
# sdb = ZFS (Block Vol).  <-- Wait, Block vols are detached separate API?
# 'boot-volume-attachment list' only lists Boot Volumes.
# 'volume-attachment list' lists Block Volumes (`sdb` and `sdc`).
# Stopping inst does not detach Block Volumes automatically (they stay attached).
# So `sdb` should be there.
# The NEW v6 (`boot volume`) should appear as `sdd` or `sde`.
ssh -o StrictHostKeyChecking=no -i /home/ilja/.ssh/id_rsa root@207.127.91.190 "
  udevadm settle
  lsblk
  # Find 50G disk that is NOT sda (active), NOT sdb (ZFS src).
  DEST=\$(lsblk -dn -o NAME,SIZE,TYPE | grep '50G disk' | grep -v 'sda' | grep -v 'sdb' | awk '{print \$1}')
  if [ -z \"\$DEST\" ]; then echo 'FAILURE: No disk found'; exit 1; fi
  echo \"Target: /dev/\$DEST\"
  dd if=/dev/sdb of=/dev/\$DEST bs=4M status=progress conv=fsync
"

echo ">>> DD DONE. v6 ($VOL_ID) now contains ZFS."
