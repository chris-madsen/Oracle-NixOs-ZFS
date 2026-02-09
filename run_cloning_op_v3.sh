#!/bin/bash
set -e

# Config
COMPARTMENT="ocid1.tenancy.oc1..aaaaaaaattopmnafstk26itnb7t3dqgqdprecczpuze2tdje4xuywzhoogqa"
AD="dVBP:EU-STOCKHOLM-1-AD-1"
NAME="NixOS-ZFS-Boot-Final"
INSTANCE_ID="ocid1.instance.oc1.eu-stockholm-1.anqxeljr2dnu37acx4h3xk4a3b7fn3zr5gjsqzv2zcqmdexnwqc2ab3j3tmq"

echo ">>> Finding Source Boot Volume..."
SRC_BOOT_ID=$(oci compute boot-volume-attachment list --instance-id "$INSTANCE_ID" --availability-domain "$AD" --compartment-id "$COMPARTMENT" --query 'data[0]."boot-volume-id"' --raw-output)
echo "Source Boot Vol: $SRC_BOOT_ID"

echo ">>> Creating Boot Volume Clone..."
VOL_ID=$(oci bv boot-volume create --availability-domain "$AD" --compartment-id "$COMPARTMENT" --source-boot-volume-id "$SRC_BOOT_ID" --size-in-gbs 50 --display-name "$NAME" --wait-for-state AVAILABLE --query 'data.id' --raw-output)
echo "New Volume: $VOL_ID"

echo ">>> Attaching Volume..."
ATTACH_ID=$(oci compute boot-volume-attachment attach --boot-volume-id "$VOL_ID" --instance-id "$INSTANCE_ID" --wait-for-state ATTACHED --query 'data.id' --raw-output)
echo "Attached: $ATTACH_ID"

echo ">>> Sleeping 20s for device settle..."
sleep 20

echo ">>> Starting Remote DD..."
# We clone sdb (ZFS) to sdd (The new clone of TempOS, which we verify is 50G)
ssh -o StrictHostKeyChecking=no -i /home/ilja/.ssh/id_rsa root@207.127.91.190 "lsblk; dd if=/dev/sdb of=/dev/sdd bs=4M status=progress conv=fsync"

echo ">>> Detaching..."
oci compute boot-volume-attachment detach --boot-volume-attachment-id "$ATTACH_ID" --wait-for-state DETACHED

echo ">>> SUCCESS. New Boot Volume: $VOL_ID"
