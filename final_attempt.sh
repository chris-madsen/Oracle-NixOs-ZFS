#!/bin/bash
set -e
# Clean up old
OLD="ocid1.bootvolume.oc1.eu-stockholm-1.abqxeljroace6coghkk4rz4imx5nlubbj5sruvmfmsa3fxgabsttpdof2qya"
oci bv boot-volume delete --boot-volume-id "$OLD" --force || true

# Config
COMP="ocid1.tenancy.oc1..aaaaaaaattopmnafstk26itnb7t3dqgqdprecczpuze2tdje4xuywzhoogqa"
AD="dVBP:EU-STOCKHOLM-1-AD-1"
SRC=$(oci compute boot-volume-attachment list --instance-id "ocid1.instance.oc1.eu-stockholm-1.anqxeljr2dnu37acx4h3xk4a3b7fn3zr5gjsqzv2zcqmdexnwqc2ab3j3tmq" --availability-domain "$AD" --compartment-id "$COMP" --query 'data[0]."boot-volume-id"' --raw-output)

echo "Creating v3..."
VOL_ID=$(oci bv boot-volume create --availability-domain "$AD" --compartment-id "$COMP" --source-boot-volume-id "$SRC" --size-in-gbs 50 --display-name "NixOS-Boot-v3" --wait-for-state AVAILABLE --query 'data.id' --raw-output)

echo "Attaching..."
ATT_ID=$(oci compute boot-volume-attachment attach --boot-volume-id "$VOL_ID" --instance-id "ocid1.instance.oc1.eu-stockholm-1.anqxeljr2dnu37acx4h3xk4a3b7fn3zr5gjsqzv2zcqmdexnwqc2ab3j3tmq" --wait-for-state ATTACHED --query 'data.id' --raw-output)

echo "DD..."
ssh -o StrictHostKeyChecking=no -i /home/ilja/.ssh/id_rsa root@207.127.91.190 "
  udevadm settle
  DEST=\$(lsblk -dn -o NAME,SIZE,TYPE | grep '50G disk' | grep -v 'sda' | grep -v 'sdb' | awk '{print \$1}')
  echo \"Target: /dev/\$DEST\"
  dd if=/dev/sdb of=/dev/\$DEST bs=4M status=progress conv=fsync
"

echo "Detaching..."
oci compute boot-volume-attachment detach --boot-volume-attachment-id "$ATT_ID" --wait-for-state DETACHED

echo "SUCCESS: $VOL_ID"
