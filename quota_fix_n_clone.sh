#!/bin/bash
set -e

COMP="ocid1.tenancy.oc1..aaaaaaaattopmnafstk26itnb7t3dqgqdprecczpuze2tdje4xuywzhoogqa"
AD="dVBP:EU-STOCKHOLM-1-AD-1"
INSTANCE="ocid1.instance.oc1.eu-stockholm-1.anqxeljr2dnu37acx4h3xk4a3b7fn3zr5gjsqzv2zcqmdexnwqc2ab3j3tmq"

echo ">>> Cleaning up old boot volumes..."
# List all boot volumes matching pattern and delete them
# We pipe to jq to filter out the *current* boot volume if possible, but names help.
# Current boot volume name is "boot-volume" (from tofu) or generic.
# We generated names "NixOS-ZFS-Boot-Final" etc.
# We delete everything containing "Final" or "v2" or "v3" or "check".
TO_DELETE=$(oci bv boot-volume list --compartment-id "$COMP" --availability-domain "$AD" --all --output json | jq -r '.data[] | select(.["display-name"] | contains("Final") or contains("v2") or contains("v3")) | .id')

if [ -n "$TO_DELETE" ]; then
  echo "$TO_DELETE" | while read vol; do
    echo "Deleting $vol..."
    oci bv boot-volume delete --boot-volume-id "$vol" --force || echo "Delete failed"
  done
  echo "Cleaned."
  sleep 10
else
  echo "Nothing to clean."
fi

# Check quota/space? Assuming freed.

echo ">>> Creating ONE FINAL BOOT VOLUME..."
# Source from CURRENT BOOT (sda) to ensure it is bootable metadata-wise
SRC_BOOT=$(oci compute boot-volume-attachment list --instance-id "$INSTANCE" --availability-domain "$AD" --compartment-id "$COMP" --query 'data[0]."boot-volume-id"' --raw-output)

VOL_ID=$(oci bv boot-volume create --availability-domain "$AD" --compartment-id "$COMP" --source-boot-volume-id "$SRC_BOOT" --size-in-gbs 50 --display-name "NixOS-ZFS-Switch-Ready" --wait-for-state AVAILABLE --query 'data.id' --raw-output)
echo "Created: $VOL_ID"

echo ">>> Attaching..."
ATTACH_ID=$(oci compute boot-volume-attachment attach --boot-volume-id "$VOL_ID" --instance-id "$INSTANCE" --wait-for-state ATTACHED --query 'data.id' --raw-output)
echo "Attached: $ATTACH_ID"

echo ">>> DD (Cloning ZFS)..."
ssh -o StrictHostKeyChecking=no -i /home/ilja/.ssh/id_rsa root@207.127.91.190 "
  udevadm settle
  # Find the new 50G disk. 
  # sda=50, sdb=50, sdc=100. New=50.
  # It will likely be /dev/sdd.
  DEST=\$(lsblk -dn -o NAME,SIZE,TYPE | grep '50G disk' | grep -v 'sda' | grep -v 'sdb' | awk '{print \$1}')
  if [ -z \"\$DEST\" ]; then echo 'FAILURE: No disk found'; exit 1; fi
  echo \"Target: /dev/\$DEST\"
  dd if=/dev/sdb of=/dev/\$DEST bs=4M status=progress conv=fsync
"

echo ">>> Detaching..."
oci compute boot-volume-attachment detach --boot-volume-attachment-id "$ATTACH_ID" --wait-for-state DETACHED

echo "SUCCESS. READY TO SWITCH: $VOL_ID"
