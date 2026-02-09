#!/bin/bash
COMP="ocid1.tenancy.oc1..aaaaaaaattopmnafstk26itnb7t3dqgqdprecczpuze2tdje4xuywzhoogqa"
AD="dVBP:EU-STOCKHOLM-1-AD-1"
ACTIVE_BOOT="ocid1.bootvolume.oc1.eu-stockholm-1.abqxeljrrkx2t4bjoz3romv7obsx5dffxi6qyiv6hlc3fquwetl7lrlamjwa"

echo "Listing Boot Volumes to Delete (Pattern: NixOS-Boot-v* or ...Final)..."
TO_DELETE=$(oci bv boot-volume list --compartment-id "$COMP" --availability-domain "$AD" --all --output json | jq -r ".data[] | select(.[\"display-name\"] | test(\"NixOS-Boot-v[0-9]|Final\")) | .id")

if [ -n "$TO_DELETE" ]; then
  echo "$TO_DELETE" | while read vol; do
    echo "Deleting $vol..."
    oci bv boot-volume delete --boot-volume-id "$vol" --force --wait-for-state TERMINATED
  done
  echo "Cleanup Complete."
else
  echo "No garbage boot volumes found."
fi
