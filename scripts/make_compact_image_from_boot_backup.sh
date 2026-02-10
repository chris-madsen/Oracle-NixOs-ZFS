#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Creates a custom image from an instance, exports it as QCOW2 to Object Storage,
and prints the exported object size (what you pay for in Object Storage).

Important: OCI CLI/API does NOT support "create custom image directly from boot volume backup".
To pin the exact NixOS+ZFS state publicly, you export a QCOW2 image and share its Object Storage
URL (typically via PAR). A boot-volume-backup OCID isn't useful to random GitHub users because
they can't access your tenancy anyway.

Usage:
  make_compact_image_from_boot_backup.sh \
    --instance-id <ocid1.instance...> \
    --compartment-id <ocid1.compartment...> \
    --bucket <bucket-name> \
    [--object <object-name.qcow2>] \
    [--image-name <display-name>] \
    [--wait-secs <seconds>] \
    [--skip-export]

Or resolve instance-id from a public IP:
  make_compact_image_from_boot_backup.sh \
    --public-ip <x.x.x.x> \
    --compartment-id <ocid1.compartment...> \
    --bucket <bucket-name>

Example:
  ./scripts/make_compact_image_from_boot_backup.sh \
    --public-ip 207.127.94.207 \
    --compartment-id ocid1.tenancy... \
    --bucket nixos-public-images \
    --object nixos-zfs-boot.qcow2 \
    --image-name nixos-zfs-boot-2026-02-09
USAGE
}

instance_id=""
public_ip=""
image_id=""
compartment_id=""
bucket=""
object=""
image_name=""
wait_secs=7200
skip_export=0

while [ "${1:-}" != "" ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --instance-id) instance_id="${2:-}"; shift 2 ;;
    --public-ip) public_ip="${2:-}"; shift 2 ;;
    --image-id) image_id="${2:-}"; shift 2 ;;
    --compartment-id) compartment_id="${2:-}"; shift 2 ;;
    --bucket) bucket="${2:-}"; shift 2 ;;
    --object) object="${2:-}"; shift 2 ;;
    --image-name) image_name="${2:-}"; shift 2 ;;
    --wait-secs) wait_secs="${2:-}"; shift 2 ;;
    --skip-export) skip_export=1; shift 1 ;;
    *) echo "Unknown arg: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [ -z "$compartment_id" ] || [ -z "$bucket" ]; then
  echo "ERROR: --compartment-id and --bucket are required." >&2
  usage >&2
  exit 2
fi

if [ -z "$image_name" ]; then
  image_name="nixos-zfs-boot-$(date +%F-%H%M%S)"
fi
if [ -z "$object" ]; then
  object="${image_name}.qcow2"
fi

if ! command -v oci >/dev/null 2>&1; then
  echo "ERROR: oci CLI not found in PATH." >&2
  exit 1
fi

human_size() {
  # Print bytes as a readable IEC value without depending on numfmt.
  # shellcheck disable=SC2016
  awk -v b="$1" 'BEGIN{
    split("B KiB MiB GiB TiB PiB",u," ");
    s=b+0; i=1;
    while (s>=1024 && i<6) { s=s/1024; i++ }
    printf "%.2f %s", s, u[i]
  }'
}

if [ -z "$image_id" ] && [ -z "$instance_id" ]; then
  if [ -z "$public_ip" ]; then
    echo "ERROR: Provide --image-id, --instance-id, or --public-ip." >&2
    usage >&2
    exit 2
  fi

  private_ip_id="$(oci network public-ip get --public-ip-address "$public_ip" --query 'data."assigned-entity-id"' --raw-output)"
  vnic_id="$(oci network private-ip get --private-ip-id "$private_ip_id" --query 'data."vnic-id"' --raw-output)"
  instance_id="$(oci compute vnic-attachment list --compartment-id "$compartment_id" --vnic-id "$vnic_id" --query 'data[0]."instance-id"' --raw-output)"
fi

if [ -z "$image_id" ]; then
  echo "Creating custom image from instance..."
  echo "  instance_id:    $instance_id"
  echo "  compartment_id: $compartment_id"
  echo "  image_name:     $image_name"

  image_id="$(oci compute image create \
    --compartment-id "$compartment_id" \
    --display-name "$image_name" \
    --instance-id "$instance_id" \
    --wait-for-state AVAILABLE \
    --query 'data.id' --raw-output)"

  echo "Image OCID: $image_id"
else
  echo "Using existing image:"
  echo "  image_id: $image_id"
fi

ns="$(oci os ns get --query 'data' --raw-output)"
echo "Object Storage namespace: $ns"

if ! oci os bucket get -ns "$ns" -bn "$bucket" >/dev/null 2>&1; then
  echo "Bucket '$bucket' not found; creating..."
  oci os bucket create -ns "$ns" --name "$bucket" --compartment-id "$compartment_id" >/dev/null
fi

if [ "$skip_export" -eq 0 ]; then
  echo "Exporting image to Object Storage as QCOW2..."
  echo "  bucket:  $bucket"
  echo "  object:  $object"

  oci compute image export to-object \
    --image-id "$image_id" \
    --export-format QCOW2 \
    -ns "$ns" -bn "$bucket" \
    --name "$object" >/dev/null
else
  echo "Skipping export request; only waiting and reporting object size."
fi

deadline=$(( $(date +%s) + wait_secs ))
state=""
if [ "$skip_export" -eq 0 ]; then
  echo "Waiting for export to finish (up to ${wait_secs}s)..."
  while :; do
    state="$(oci compute image get --image-id "$image_id" --query 'data."lifecycle-state"' --raw-output)"
    if [ "$state" != "EXPORTING" ]; then
      break
    fi
    if [ "$(date +%s)" -ge "$deadline" ]; then
      echo "ERROR: Timed out waiting for image export to finish (still EXPORTING)." >&2
      exit 1
    fi
    sleep 30
  done
  echo "Image lifecycle-state: $state"
fi
echo "Waiting for exported object to be available (up to ${wait_secs}s total)..."
while :; do
  if oci os object head -ns "$ns" -bn "$bucket" --name "$object" >/dev/null 2>&1; then
    bytes="$(oci os object head -ns "$ns" -bn "$bucket" --name "$object" --query '"content-length"' --raw-output)"
    # During export OCI may briefly write a tiny status JSON; wait until it looks like a real image.
    if [ "${bytes:-0}" -ge 1048576 ]; then
      break
    fi
  fi
  if [ "$(date +%s)" -ge "$deadline" ]; then
    echo "ERROR: Timed out waiting for exported object to become large enough." >&2
    echo "Current objects:" >&2
    oci os object list -ns "$ns" -bn "$bucket" --query 'data[].{name:name,size:size}' --output table >&2 || true
    exit 1
  fi
  sleep 30
done

echo "Exported object size: ${bytes} bytes ($(human_size "$bytes"))"
