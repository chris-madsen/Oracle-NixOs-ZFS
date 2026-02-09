#!/bin/bash
set -e

# Config from previous step
VOL_ID="ocid1.bootvolume.oc1.eu-stockholm-1.abqxeljroace6coghkk4rz4imx5nlubbj5sruvmfmsa3fxgabsttpdof2qya"
INSTANCE_ID="ocid1.instance.oc1.eu-stockholm-1.anqxeljr2dnu37acx4h3xk4a3b7fn3zr5gjsqzv2zcqmdexnwqc2ab3j3tmq"

echo ">>> Attaching (Ignorning Conflicts)..."
ATTACH_OUT=$(oci compute boot-volume-attachment attach --boot-volume-id "$VOL_ID" --instance-id "$INSTANCE_ID" --wait-for-state ATTACHED --query 'data.id' --raw-output 2>&1 || true)

if echo "$ATTACH_OUT" | grep -q "Conflict"; then
    echo "Already attached. Finding attachment ID..."
    ATTACH_ID=$(oci compute boot-volume-attachment list --instance-id "$INSTANCE_ID" --availability-domain "dVBP:EU-STOCKHOLM-1-AD-1" --compartment-id "ocid1.tenancy.oc1..aaaaaaaattopmnafstk26itnb7t3dqgqdprecczpuze2tdje4xuywzhoogqa" --all --output json | jq -r ".data[] | select(.[\"boot-volume-id\"] == \"$VOL_ID\") | .id")
else
    ATTACH_ID=$ATTACH_OUT
fi
echo "Attachment ID: $ATTACH_ID"

echo ">>> Starting Remote DD..."
# sda=boot(50G), sdb=src(50G), sdc=data(100G). New one is 50G.
# Logic: Find 50G disk that is NOT sda or sdb.
ssh -o StrictHostKeyChecking=no -i /home/ilja/.ssh/id_rsa root@207.127.91.190 "
  DEST=\$(lsblk -dn -o NAME,SIZE,TYPE | grep '50G disk' | grep -v 'sda' | grep -v 'sdb' | awk '{print \$1}')
  if [ -z \"\$DEST\" ]; then echo 'No dest disk found!'; exit 1; fi
  echo \"Target Device: /dev/\$DEST\"
  dd if=/dev/sdb of=/dev/\$DEST bs=4M status=progress conv=fsync
"

echo ">>> Detaching..."
oci compute boot-volume-attachment detach --boot-volume-attachment-id "$ATTACH_ID" --wait-for-state DETACHED

echo ">>> DONE. New Boot Volume Ready: $VOL_ID"
