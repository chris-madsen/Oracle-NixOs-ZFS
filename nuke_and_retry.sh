#!/bin/bash
set -e

COMP="ocid1.tenancy.oc1..aaaaaaaattopmnafstk26itnb7t3dqgqdprecczpuze2tdje4xuywzhoogqa"
AD="dVBP:EU-STOCKHOLM-1-AD-1"
INSTANCE="ocid1.instance.oc1.eu-stockholm-1.anqxeljr2dnu37acx4h3xk4a3b7fn3zr5gjsqzv2zcqmdexnwqc2ab3j3tmq"
ACTIVE_BOOT="ocid1.bootvolume.oc1.eu-stockholm-1.abqxeljrrkx2t4bjoz3romv7obsx5dffxi6qyiv6hlc3fquwetl7lrlamjwa"

echo ">>> NUKING OLD VOLUMES..."
# List ALL and filter by Name manually to be safe.
# We keep ACTIVE_BOOT.
# We verify Display Name is 'NixOS-Boot-v*' or '...Final'.
# Using jq logic.
TO_NUKE=$(oci bv boot-volume list --compartment-id "$COMP" --availability-domain "$AD" --all --output json | jq -r ".data[] | select(.id != \"$ACTIVE_BOOT\") | select(.[\"display-name\"] | test(\"NixOS.*\")) | .id")

if [ -n "$TO_NUKE" ]; then
  echo "$TO_NUKE" | while read vol; do
    echo "Nuking $vol..."
    oci bv boot-volume delete --boot-volume-id "$vol" --force --wait-for-state TERMINATED || echo "Failed to delete $vol (Attached?)"
  done
else
  echo "Clean."
fi

echo ">>> Creating Boot Volume v5..."
SRC_BOOT="$ACTIVE_BOOT"
VOL_ID=$(oci bv boot-volume create --availability-domain "$AD" --compartment-id "$COMP" --source-boot-volume-id "$SRC_BOOT" --size-in-gbs 50 --display-name "NixOS-Boot-v5" --wait-for-state AVAILABLE --query 'data.id' --raw-output)
echo "Created: $VOL_ID"

echo ">>> Attaching..."
# Explicit attempt
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
