#!/bin/bash
set -e

INSTANCE="ocid1.instance.oc1.eu-stockholm-1.anqxeljr2dnu37acx4h3xk4a3b7fn3zr5gjsqzv2zcqmdexnwqc2ab3j3tmq"
COMP="ocid1.tenancy.oc1..aaaaaaaattopmnafstk26itnb7t3dqgqdprecczpuze2tdje4xuywzhoogqa"
AD="dVBP:EU-STOCKHOLM-1-AD-1"

echo ">>> Pruning Zombie Attachments..."
# List all attachments
# Filter out the ACTIVE BOOT volume (sda).
# We need to know which one is active boot. Usually it is the one created with instance.
# We will identify it by 'lifecycle-state': 'ATTACHED' and check if we can query index?
# Or just exclude known good ID. 
# Active Boot Volume ID (sda) from previous log: ...mjwa
ACTIVE_BOOT="ocid1.bootvolume.oc1.eu-stockholm-1.abqxeljrrkx2t4bjoz3romv7obsx5dffxi6qyiv6hlc3fquwetl7lrlamjwa"

ALL_ATTS=$(oci compute boot-volume-attachment list --instance-id "$INSTANCE" --availability-domain "$AD" --compartment-id "$COMP" --all --output json)

# Parse IDs to detach (All minus Active)
IDS_TO_DETACH=$(echo "$ALL_ATTS" | jq -r ".data[] | select(.[\"boot-volume-id\"] != \"$ACTIVE_BOOT\") | .id")

if [ -n "$IDS_TO_DETACH" ]; then
  echo "$IDS_TO_DETACH" | while read att_id; do
    echo "Detaching zombie attachment: $att_id"
    oci compute boot-volume-attachment detach --boot-volume-attachment-id "$att_id" --force || echo "Detach request sent/failed"
  done
  echo "Waiting 30s for detach..."
  sleep 30
else
  echo "No zombies found."
fi

echo ">>> Creating Boot Volume v4..."
# Clean up prev attempt v3? (optional, quota is fine)
SRC_BOOT="$ACTIVE_BOOT"
VOL_ID=$(oci bv boot-volume create --availability-domain "$AD" --compartment-id "$COMP" --source-boot-volume-id "$SRC_BOOT" --size-in-gbs 50 --display-name "NixOS-Boot-v4" --wait-for-state AVAILABLE --query 'data.id' --raw-output)
echo "Created: $VOL_ID"

echo ">>> Attaching..."
# Explicitly use retries or ignore failure if already attached? No, fresh volume.
ATTACH_ID=$(oci compute boot-volume-attachment attach --boot-volume-id "$VOL_ID" --instance-id "$INSTANCE" --wait-for-state ATTACHED --query 'data.id' --raw-output)
echo "Attached: $ATTACH_ID"

echo ">>> DD..."
ssh -o StrictHostKeyChecking=no -i /home/ilja/.ssh/id_rsa root@207.127.91.190 "
  udevadm settle
  DEST=\$(lsblk -dn -o NAME,SIZE,TYPE | grep '50G disk' | grep -v 'sda' | grep -v 'sdb' | awk '{print \$1}')
  if [ -z \"\$DEST\" ]; then echo 'FAILURE: No disk found'; exit 1; fi
  echo \"Target: /dev/\$DEST\"
  dd if=/dev/sdb of=/dev/\$DEST bs=4M status=progress conv=fsync
"

echo ">>> Detaching..."
oci compute boot-volume-attachment detach --boot-volume-attachment-id "$ATTACH_ID" --wait-for-state DETACHED

echo "SUCCESS: $VOL_ID"
