#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Creates a custom image from an instance (or uses an existing image) and shares it.

Note: OCI does NOT support making a boot volume backup "public for everyone".
You have two realistic options:
  1) Share the created custom image to a specific tenancy (needs their tenancy OCID).
  2) Export the created image to Object Storage and create a pre-authenticated request (PAR) URL.
     Anyone with the PAR URL can import the image into their own tenancy.

Usage:
  share_boot_backup_image.sh --instance-id <ocid1.instance...> --compartment-id <ocid1.compartment...> \
    [--image-id <ocid1.image...>] [--public-ip <x.x.x.x>] \
    [--target-tenancy-id <ocid1.tenancy...>] \
    [--export-bucket <bucket>] [--export-object <name>] [--export-format <OCI|QCOW2|...>] [--create-par] [--par-hours <hours>] \
    [--name <display-name>] [--no-wait]

Examples:
  ./share_boot_backup_image.sh \
    --instance-id ocid1.instance... \
    --compartment-id ocid1.tenancy... \
    --target-tenancy-id ocid1.tenancy... \
    --name "nixos-zfs-boot-2026-02-09"

  ./share_boot_backup_image.sh \
    --instance-id ocid1.instance... \
    --compartment-id ocid1.tenancy... \
    --export-bucket public-images \
    --export-object nixos-zfs-boot.oci \
    --create-par --par-hours 168
USAGE
}

backup_id="" # kept only to error out with a helpful message
instance_id=""
public_ip=""
image_id=""
compartment_id=""
target_tenancy_id=""
name=""
wait=1
export_bucket=""
export_object=""
export_format="OCI"
create_par=0
par_hours=168

while [ "${1:-}" != "" ]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --backup-id)
      backup_id="${2:-}"; shift 2
      ;;
    --instance-id)
      instance_id="${2:-}"; shift 2
      ;;
    --public-ip)
      public_ip="${2:-}"; shift 2
      ;;
    --image-id)
      image_id="${2:-}"; shift 2
      ;;
    --compartment-id)
      compartment_id="${2:-}"; shift 2
      ;;
    --target-tenancy-id)
      target_tenancy_id="${2:-}"; shift 2
      ;;
    --export-bucket)
      export_bucket="${2:-}"; shift 2
      ;;
    --export-object)
      export_object="${2:-}"; shift 2
      ;;
    --export-format)
      export_format="${2:-}"; shift 2
      ;;
    --create-par)
      create_par=1; shift 1
      ;;
    --par-hours)
      par_hours="${2:-}"; shift 2
      ;;
    --name)
      name="${2:-}"; shift 2
      ;;
    --no-wait)
      wait=0; shift 1
      ;;
    *)
      echo "Unknown arg: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [ -n "$backup_id" ]; then
  echo "ERROR: OCI CLI can't create a custom image directly from a boot volume backup OCID." >&2
  echo "Use --instance-id (recommended) or provide an existing --image-id." >&2
  exit 2
fi

if [ -z "$compartment_id" ]; then
  echo "ERROR: --compartment-id is required." >&2
  usage >&2
  exit 2
fi

if [ -z "$name" ]; then
  # Keep it ASCII and predictable for Terraform references.
  name="boot-backup-image-$(date +%F-%H%M%S)"
fi

if ! command -v oci >/dev/null 2>&1; then
  echo "ERROR: oci CLI not found in PATH." >&2
  exit 1
fi

if [ -z "$image_id" ]; then
  if [ -z "$instance_id" ]; then
    if [ -z "$public_ip" ]; then
      echo "ERROR: Provide --image-id or --instance-id (or --public-ip to resolve instance-id)." >&2
      usage >&2
      exit 2
    fi

    # Resolving via public IP can fail for ephemeral IPs; use --instance-id when possible.
    private_ip_id="$(oci network public-ip get --public-ip-address "$public_ip" --query 'data."assigned-entity-id"' --raw-output)"
    vnic_id="$(oci network private-ip get --private-ip-id "$private_ip_id" --query 'data."vnic-id"' --raw-output)"
    instance_id="$(oci compute vnic-attachment list --compartment-id "$compartment_id" --vnic-id "$vnic_id" --query 'data[0]."instance-id"' --raw-output)"
  fi
fi

get_region() {
  if [ -n "${OCI_CLI_REGION:-}" ]; then
    printf '%s\n' "$OCI_CLI_REGION"
    return 0
  fi

  local cfg profile
  cfg="${OCI_CLI_CONFIG_FILE:-$HOME/.oci/config}"
  profile="${OCI_CLI_PROFILE:-DEFAULT}"

  if [ -r "$cfg" ]; then
    awk -v profile="[$profile]" '
      $0 == profile { in=1; next }
      /^\[/ { in=0 }
      in && $1 ~ /^region[[:space:]]*=/ {
        sub(/^region[[:space:]]*=[[:space:]]*/, "", $0);
        gsub(/[[:space:]]+$/, "", $0);
        print $0; exit 0
      }
    ' "$cfg" || true
  fi
}

echo "Creating custom image..."
if [ -z "$image_id" ]; then
  echo "  instance_id:    $instance_id"
  echo "  compartment_id: $compartment_id"
  echo "  name:           $name"

  create_args=(
    compute image create
    --compartment-id "$compartment_id"
    --display-name "$name"
    --instance-id "$instance_id"
    --query 'data.id'
    --raw-output
  )

  if [ "$wait" -eq 1 ]; then
    create_args+=(--wait-for-state AVAILABLE --max-wait-seconds 7200)
  fi

  image_id="$(oci "${create_args[@]}")"
else
  echo "Using existing image:"
  echo "  image_id: $image_id"
fi
echo "Image OCID: $image_id"

if [ -n "$target_tenancy_id" ]; then
  echo "Adding image launch permission for tenancy: $target_tenancy_id"
  oci compute image add-image-launch-permission \
    --image-id "$image_id" \
    --tenant-id "$target_tenancy_id" >/dev/null

  echo "Launch permissions:"
  oci compute image list-image-launch-permissions \
    --image-id "$image_id" \
    --query 'data[].{tenantId:"tenant-id"}' \
    --output table
else
  echo "No --target-tenancy-id provided; image is created but not shared."
fi

if [ -n "$export_bucket" ]; then
  if [ -z "$export_object" ]; then
    export_object="${name}.oci"
  fi

  echo "Preparing Object Storage export..."
  ns="$(oci os ns get --query 'data' --raw-output)"
  echo "  namespace: $ns"
  echo "  bucket:    $export_bucket"
  echo "  object:    $export_object"
  echo "  format:    $export_format"

  if ! oci os bucket get -ns "$ns" -bn "$export_bucket" >/dev/null 2>&1; then
    echo "Bucket does not exist; creating..."
    oci os bucket create -ns "$ns" --name "$export_bucket" --compartment-id "$compartment_id" >/dev/null
  fi

  echo "Exporting image to Object Storage (this can take a while)..."
  oci compute image export to-object \
    --image-id "$image_id" \
    -ns "$ns" -bn "$export_bucket" \
    --name "$export_object" \
    --export-format "$export_format" >/dev/null

  echo "Waiting for the exported object to appear..."
  # Export may first write a tiny status JSON; wait until it looks like a real image.
  deadline=$(( $(date +%s) + 14400 ))
  bytes=""
  while :; do
    if oci os object head -ns "$ns" -bn "$export_bucket" --name "$export_object" >/dev/null 2>&1; then
      bytes="$(oci os object head -ns "$ns" -bn "$export_bucket" --name "$export_object" --query '"content-length"' --raw-output)"
      if [ "${bytes:-0}" -ge 1048576 ]; then
        break
      fi
    fi
    if [ "$(date +%s)" -ge "$deadline" ]; then
      echo "WARNING: export started but object is still small/not visible. Check later:" >&2
      echo "  oci os object head -ns \"$ns\" -bn \"$export_bucket\" --name \"$export_object\"" >&2
      break
    fi
    sleep 30
  done

  if [ "$create_par" -eq 1 ]; then
    region="$(get_region)"
    if [ -z "$region" ]; then
      echo "ERROR: Unable to determine region for PAR URL. Set OCI_CLI_REGION or configure region in ~/.oci/config." >&2
      exit 1
    fi
    if ! [[ "$par_hours" =~ ^[0-9]+$ ]] || [ "$par_hours" -lt 1 ]; then
      echo "ERROR: --par-hours must be a positive integer." >&2
      exit 2
    fi

    expires="$(date -u -d "+${par_hours} hours" +%Y-%m-%dT%H:%M:%SZ)"
    par_name="par-${export_object}-$(date -u +%Y%m%d%H%M%S)"
    echo "Creating PAR (ObjectRead) valid until: $expires"
    access_uri="$(oci os preauth-request create -ns "$ns" -bn "$export_bucket" \
      --name "$par_name" --access-type ObjectRead --time-expires "$expires" --object-name "$export_object" \
      --query 'data."access-uri"' --raw-output)"

    par_url="https://objectstorage.${region}.oraclecloud.com${access_uri}"
    echo "PAR URL (publish this):"
    echo "$par_url"
    echo
    echo "Import example (run in any tenancy):"
    echo "  oci compute image import from-object-uri --compartment-id <their_compartment_ocid> --display-name \"$name\" --source-image-type QCOW2 --uri \"$par_url\""
  fi
fi
