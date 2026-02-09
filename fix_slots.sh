#!/bin/bash
set -e
VOL_V3="ocid1.bootvolume.oc1.eu-stockholm-1.abqxeljrxbr3mbzamphb2xzsd64gn4wxaiyqnzkkn5axkeg6455k4idalhyq"
INSTANCE="ocid1.instance.oc1.eu-stockholm-1.anqxeljr2dnu37acx4h3xk4a3b7fn3zr5gjsqzv2zcqmdexnwqc2ab3j3tmq"
DATA_VOL_ID="ocid1.volume.oc1.eu-stockholm-1.abqxeljrql4cbjlc5lzelp6yk4blvl7li5e6fq7fy6f5xhjoykqnrhgs756a" # Retrieved from state earlier

echo "Finding Data Attachment..."
DATA_ATT=$(oci compute boot-volume-attachment list --instance-id "$INSTANCE" --all --output json | jq -r ".data[] | select(.[\"boot-volume-id\"] == \"$DATA_VOL_ID\") | .id")
# Wait, data is BLOCK volume. Not boot volume attachment.
if [ -z "$DATA_ATT" ]; then
  DATA_ATT=$(oci compute volume-attachment list --instance-id "$INSTANCE" --all --output json | jq -r ".data[] | select(.[\"volume-id\"] == \"$DATA_VOL_ID\") | .id")
fi
echo "Data Att: $DATA_ATT"

echo "Detaching Data Volume (to free slot)..."
oci compute volume-attachment detach --volume-attachment-id "$DATA_ATT" --wait-for-state DETACHED || echo "Already detach? or failed"

echo "Re-attaching Boot Clone v3..."
# First check if attached
ATT_V3=$(oci compute boot-volume-attachment list --instance-id "$INSTANCE" --all --output json | jq -r ".data[] | select(.[\"boot-volume-id\"] == \"$VOL_V3\") | .id")
if [ -n "$ATT_V3" ]; then
   echo "Found ghost attachment for v3: $ATT_V3. Detaching it first to reset."
   oci compute boot-volume-attachment detach --boot-volume-attachment-id "$ATT_V3" --wait-for-state DETACHED
fi

echo "Attaching v3..."
ATT_FINAL=$(oci compute boot-volume-attachment attach --boot-volume-id "$VOL_V3" --instance-id "$INSTANCE" --wait-for-state ATTACHED --query 'data.id' --raw-output)

echo "DD..."
ssh -o StrictHostKeyChecking=no -i /home/ilja/.ssh/id_rsa root@207.127.91.190 "
  udevadm settle
  # sdc is gone. sdb is ZFS. The new one should be sdc.
  DEST=\$(lsblk -dn -o NAME,SIZE,TYPE | grep '50G disk' | grep -v 'sda' | grep -v 'sdb' | awk '{print \$1}')
  echo \"Target: /dev/\$DEST\"
  dd if=/dev/sdb of=/dev/\$DEST bs=4M status=progress conv=fsync
"

echo "Detaching new boot vol..."
oci compute boot-volume-attachment detach --boot-volume-attachment-id "$ATT_FINAL" --wait-for-state DETACHED

echo "SUCCESS: $VOL_V3"
