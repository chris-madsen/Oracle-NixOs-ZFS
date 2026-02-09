#!/bin/bash
set -e
VOL_ID="ocid1.bootvolume.oc1.eu-stockholm-1.abqxeljrwwwc23tfabq6l54kisli5vyrvdhv4ljlmf36mabcq2gue4rxgr3q"
INSTANCE_ID="ocid1.instance.oc1.eu-stockholm-1.anqxeljr2dnu37acx4h3xk4a3b7fn3zr5gjsqzv2zcqmdexnwqc2ab3j3tmq"
COMPARTMENT="ocid1.tenancy.oc1..aaaaaaaattopmnafstk26itnb7t3dqgqdprecczpuze2tdje4xuywzhoogqa"
AD="dVBP:EU-STOCKHOLM-1-AD-1"

echo "Finding attachment..."
ATTACH_ID=$(oci compute boot-volume-attachment list --instance-id "$INSTANCE_ID" --availability-domain "$AD" --compartment-id "$COMPARTMENT" --all --output json | jq -r ".data[] | select(.[\"boot-volume-id\"] == \"$VOL_ID\") | .id")

if [ -z "$ATTACH_ID" ]; then
    echo "Not found attached. Trying attach again..."
    ATTACH_ID=$(oci compute boot-volume-attachment attach --boot-volume-id "$VOL_ID" --instance-id "$INSTANCE_ID" --wait-for-state ATTACHED --query 'data.id' --raw-output)
else
    echo "Found existing attachment: $ATTACH_ID"
fi

echo ">>> Sleeping 10s..."
sleep 10

echo ">>> Starting Remote DD..."
# Warning: Clone of sda likely ended up as sdd? Or sdc?
# sda=boot, sdb=src(Block), sdc=data.
# The NEW boot volume is attached.
# OCI attaches paravirtualized as next index.
# We check lsblk. One should be 50G and match the serial logic?
# Boot volumes usually show up.
# We will use lsblk to print details.
ssh -o StrictHostKeyChecking=no -i /home/ilja/.ssh/id_rsa root@207.127.91.190 "lsblk -o NAME,SIZE,SERIAL; echo 'DANGER: Overwriting sdd'; dd if=/dev/sdb of=/dev/sdd bs=4M status=progress conv=fsync"

echo ">>> Detaching..."
oci compute boot-volume-attachment detach --boot-volume-attachment-id "$ATTACH_ID" --wait-for-state DETACHED

echo ">>> SUCCESS. Ready to switch to: $VOL_ID"
