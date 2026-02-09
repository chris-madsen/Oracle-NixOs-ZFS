# 1. OCI Provider configuration
provider "oci" {
  tenancy_ocid     = var.tenancy_ocid
  user_ocid        = var.user_ocid
  fingerprint      = var.fingerprint
  private_key_path = var.private_key_path
  region           = var.region
}

# 2. Get the list of Availability Domains (ADs)
data "oci_identity_availability_domains" "ads" {
  compartment_id = var.compartment_id
}

# 3. Dynamic Image Search (Ubuntu 24.04 ARM)
data "oci_core_images" "ubuntu_arm" {
  compartment_id           = var.compartment_id
  operating_system         = "Canonical Ubuntu"
  operating_system_version = "24.04"
  shape                    = "VM.Standard.A1.Flex"
  sort_by                  = "TIMECREATED"
  sort_order               = "DESC"
}

locals {
  nixos_config = templatefile("${path.module}/configuration.nix.tftpl", {
    ssh_key = trimspace(file(var.ssh_public_key_path))
  })
  nixos_minimal_config = templatefile("${path.module}/configuration.minimal.nix.tftpl", {
    ssh_key = trimspace(file(var.ssh_public_key_path))
  })
  flake_nix   = file("${path.module}/flake.nix.tftpl")
  disk_config = file("${path.module}/disk-config.nix")
  
  # Logic adapted: This ID is calculated but not used for boot in this configuration
  boot_source_id = length(trimspace(var.boot_source_image_id)) > 0 ? var.boot_source_image_id : data.oci_core_images.ubuntu_arm.images[0].id
  
  nixos_config_b64         = base64gzip(local.nixos_config)
  nixos_minimal_config_b64 = base64gzip(local.nixos_minimal_config)
  flake_nix_b64            = base64gzip(local.flake_nix)
  disk_config_b64          = base64gzip(local.disk_config)
  cloud_init = templatefile("${path.module}/cloud-init.yaml.tftpl", {
    nixos_config_b64         = local.nixos_config_b64
    nixos_minimal_config_b64 = local.nixos_minimal_config_b64
    flake_nix_b64            = local.flake_nix_b64
    disk_config_b64          = local.disk_config_b64
    kexec_url                = var.kexec_url
    kexec_source_url         = var.kexec_source_url
  })
  installer_payload_hash = sha256(join("", concat(
    [
      sha256(local.flake_nix),
      sha256(local.nixos_config),
      sha256(local.nixos_minimal_config),
      sha256(local.disk_config)
    ],
    [for f in fileset(path.module, "flake.lock") : filesha256("${path.module}/${f}")],
    [for f in fileset(path.module, "scripts/*") : filesha256("${path.module}/${f}")]
  )))
}

# 4. Create a Virtual Cloud Network (VCN)
resource "oci_core_vcn" "free_vcn" {
  cidr_block     = "10.0.0.0/16"
  compartment_id = var.compartment_id
  display_name   = "Free_VCN"
  dns_label      = "freevcn"
}

# 5. Create an Internet Gateway
resource "oci_core_internet_gateway" "ig" {
  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.free_vcn.id
  display_name   = "Free_Internet_Gateway"
}

# 6. Create a Custom Route Table (Explicit)
resource "oci_core_route_table" "public_rt" {
  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.free_vcn.id
  display_name   = "Public_Route_Table"

  route_rules {
    destination       = "0.0.0.0/0"
    network_entity_id = oci_core_internet_gateway.ig.id
  }
}

# 7. Create a Custom Security List (Explicit)
resource "oci_core_security_list" "public_sl" {
  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.free_vcn.id
  display_name   = "Public_Security_List"

  # Ingress: Allow SSH (Port 22) from anywhere
  ingress_security_rules {
    protocol = "6" # TCP
    source   = "0.0.0.0/0"
    tcp_options {
      min = 22
      max = 22
    }
  }

  # Ingress: Allow Bittensor axon port for e8gateway (default 8091)
  ingress_security_rules {
    protocol = "6" # TCP
    source   = "0.0.0.0/0"
    tcp_options {
      min = 8091
      max = 8091
    }
  }

  # Egress: Allow all outbound traffic (Critical for downloading NixOS)
  egress_security_rules {
    protocol    = "all"
    destination = "0.0.0.0/0"
  }
}

# 8. Create a Public Subnet (Linked to CUSTOM resources)
resource "oci_core_subnet" "public_subnet" {
  cidr_block     = "10.0.1.0/24"
  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.free_vcn.id
  display_name   = "Public_Subnet"

  # LINKING TO OUR NEW CUSTOM RESOURCES
  route_table_id    = oci_core_route_table.public_rt.id
  security_list_ids = [oci_core_security_list.public_sl.id]
}

# 9.0 Restore Boot Volume from Backup (Added step)
resource "oci_core_boot_volume" "restored_boot_volume" {
  availability_domain = data.oci_identity_availability_domains.ads.availability_domains[0].name
  compartment_id      = var.compartment_id
  display_name        = "Restored_NixOS_Root"

  source_details {
    id   = "ocid1.bootvolumebackup.oc1.eu-stockholm-1.abqxeljrrxwiztsdzkmyxy2ftn4tjff75yvupsk6ci36lipr4n2jlp74w2sa"
    type = "bootVolumeBackup"
  }
}

# 9. Create the Compute Instance (Modified to use restored volume)
# FIX: Boot volume now acts as MAIN disk (ESP + ZFS Root)
resource "oci_core_instance" "arm_instance" {
  availability_domain = data.oci_identity_availability_domains.ads.availability_domains[0].name
  compartment_id      = var.compartment_id
  shape               = "VM.Standard.A1.Flex"

  shape_config {
    ocpus         = 4
    memory_in_gbs = 24
  }

  create_vnic_details {
    subnet_id        = oci_core_subnet.public_subnet.id
    assign_public_ip = true
  }

  source_details {
    source_type = "bootVolume"
    source_id   = oci_core_boot_volume.restored_boot_volume.id
    # boot_volume_size_in_gbs cannot be set when restoring from volume, size comes from volume
  }

  metadata = {
    ssh_authorized_keys = trimspace(file(var.ssh_public_key_path))
    user_data           = base64encode(local.cloud_init)
  }

  display_name = "NixOS_ARM_Server"

  lifecycle {
    create_before_destroy = false
    ignore_changes        = [source_details]
  }
}

# 9.1 Create and attach a dedicated ZFS boot volume (/dev/sdb)
resource "oci_core_volume" "boot_volume" {
  availability_domain = data.oci_identity_availability_domains.ads.availability_domains[0].name
  compartment_id      = var.compartment_id
  display_name        = "boot-volume"
  size_in_gbs         = var.boot_pv_size_in_gbs

  lifecycle {
    create_before_destroy = false
  }
}

resource "oci_core_volume_attachment" "boot_attachment" {
  attachment_type = "paravirtualized"
  instance_id     = oci_core_instance.arm_instance.id
  volume_id       = oci_core_volume.boot_volume.id
  is_shareable    = true
  depends_on = [
    oci_core_volume.boot_volume,
  ]
}

## 10. Create and attach a dedicated data volume (/dev/sdc)
## NOTE: This attaches after boot_volume, expected as /dev/sdc
##resource "oci_core_volume" "data_volume" {
##  availability_domain = data.oci_identity_availability_domains.ads.availability_domains[0].name
##  compartment_id      = var.compartment_id
##  display_name        = "data-volume"
##  size_in_gbs         = var.data_pv_size_in_gbs
##
##  lifecycle {
##    create_before_destroy = false
##  }
##}
##
##resource "oci_core_volume_attachment" "data_attachment" {
##  attachment_type = "paravirtualized"
##  instance_id     = oci_core_instance.arm_instance.id
##  volume_id       = oci_core_volume.data_volume.id
##  is_shareable    = true
##  depends_on = [
##    oci_core_volume.data_volume,
##    oci_core_volume_attachment.boot_attachment,
##  ]
##}

# 11. Output the Public IP address
output "server_public_ip" {
  description = "Public IP of the created instance"
  value       = oci_core_instance.arm_instance.public_ip
}

# 11. Optional volume snapshots (enable via create_volume_snapshots=true)
resource "oci_core_volume_backup" "boot_volume_snapshot" {
  count        = var.create_volume_snapshots ? 1 : 0
  volume_id    = oci_core_volume.boot_volume.id
  display_name = "boot-volume-snapshot"
}

##resource "oci_core_volume_backup" "data_volume_snapshot" {
##  count        = var.create_volume_snapshots ? 1 : 0
##  volume_id    = oci_core_volume.data_volume.id
##  display_name = "data-volume-snapshot"
##}

# 12. Prepare NixOS configuration files locally
resource "local_file" "nixos_flake" {
  content  = local.flake_nix
  filename = "${path.module}/flake.nix"
}

resource "local_file" "nixos_config" {
  content  = local.nixos_config
  filename = "${path.module}/configuration.nix"
}

resource "local_file" "nixos_minimal_config" {
  content  = local.nixos_minimal_config
  filename = "${path.module}/configuration.minimal.nix"
}

resource "null_resource" "upload_installer" {
  triggers = {
    instance_id  = oci_core_instance.arm_instance.id
    payload_hash = local.installer_payload_hash
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-lc"]
    command = <<EOT
      set -euo pipefail
      HOST="${oci_core_instance.arm_instance.public_ip}"
      KEY_PATH="${var.ssh_private_key_path}"
      SSH_USER="${var.ssh_user}"
      MODULE_DIR="${path.module}"

      echo "Uploading installer payload to $SSH_USER@$HOST..."
      tmp_dir="$(mktemp -d)"
      tar_path="$(mktemp)"
      cleanup() { rm -rf "$tmp_dir" "$tar_path"; }
      trap cleanup EXIT

      cp -a "$MODULE_DIR/flake.nix" "$tmp_dir/"
      if [ -f "$MODULE_DIR/flake.lock" ]; then
        cp -a "$MODULE_DIR/flake.lock" "$tmp_dir/"
      fi
      cp -a "$MODULE_DIR/configuration.nix" "$tmp_dir/"
      cp -a "$MODULE_DIR/configuration.minimal.nix" "$tmp_dir/"
      cp -a "$MODULE_DIR/disk-config.nix" "$tmp_dir/"

      for f in "$MODULE_DIR"/scripts/*.sh "$MODULE_DIR"/scripts/*.service; do
        [ -e "$f" ] || continue
        cp -a "$f" "$tmp_dir/$(basename "$f")"
      done

      tar -czf "$tar_path" -C "$tmp_dir" .

      echo "Waiting for SSH..."
      i=0
      while [ "$i" -lt 12 ]; do
        if ssh -i "$KEY_PATH" \
            -o StrictHostKeyChecking=no \
            -o UserKnownHostsFile=/dev/null \
            -o ConnectTimeout=5 \
            -o BatchMode=yes \
            -o ServerAliveInterval=5 \
            -o ServerAliveCountMax=3 \
            "$SSH_USER@$HOST" "echo SSH_READY" >/dev/null 2>&1; then
          break
        fi
        i=$((i + 1))
        sleep 5
      done
      if [ "$i" -ge 12 ]; then
        echo "SSH not ready after 60 seconds." >&2
        exit 1
      fi

      scp -i "$KEY_PATH" \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=10 \
        -o BatchMode=yes \
        "$tar_path" "$SSH_USER@$HOST:/root/installer.tgz"

      ssh -i "$KEY_PATH" \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=10 \
        -o BatchMode=yes \
        "$SSH_USER@$HOST" \
        "rm -rf /root/installer && mkdir -p /root/installer && tar -xzf /root/installer.tgz -C /root/installer && rm -f /root/installer.tgz && chmod +x /root/installer/*.sh || true"
    EOT
  }

  depends_on = [
    oci_core_instance.arm_instance,
    local_file.nixos_flake,
    local_file.nixos_config,
    local_file.nixos_minimal_config
  ]
}

resource "null_resource" "cloud_init_logs" {
  triggers = {
    instance_id     = oci_core_instance.arm_instance.id
    cloud_init_hash = sha256(local.cloud_init)
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-lc"]
    command = <<EOT
      set -eu
      if (set -o pipefail) 2>/dev/null; then
        set -o pipefail
      fi
      HOST="${oci_core_instance.arm_instance.public_ip}"
      KEY_PATH="${var.ssh_private_key_path}"

      echo "Waiting for SSH to collect cloud-init logs..."
      i=0
      while [ "$i" -lt 12 ]; do
        if ssh -i "$KEY_PATH" \
            -o StrictHostKeyChecking=no \
            -o UserKnownHostsFile=/dev/null \
            -o ConnectTimeout=5 \
            -o BatchMode=yes \
            -o ServerAliveInterval=5 \
            -o ServerAliveCountMax=3 \
            ubuntu@"$HOST" "echo SSH_READY" >/dev/null 2>&1; then
          break
        fi
        i=$((i + 1))
        sleep 5
      done
      if [ "$i" -ge 12 ]; then
        echo "SSH not ready after 60s; skipping log collection."
        exit 0
      fi

      ssh -i "$KEY_PATH" \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=10 \
        -o BatchMode=yes \
        -o ServerAliveInterval=5 \
        -o ServerAliveCountMax=3 \
        ubuntu@"$HOST" \
        "sudo cloud-init status --long || true; \
         sudo test -f /var/log/cloud-init-output.log && sudo tail -n 200 /var/log/cloud-init-output.log || true; \
         sudo test -f /var/log/cloud-init.log && sudo tail -n 200 /var/log/cloud-init.log || true; \
         sudo test -f /var/log/nixos-bootstrap.log && sudo tail -n 200 /var/log/nixos-bootstrap.log || true" \
        || true
    EOT
    on_failure = continue
  }

  depends_on = [
    oci_core_instance.arm_instance,
    # REMOVED: oci_core_volume_attachment.system_attachment
    # oci_core_volume_attachment.data_attachment
  ]
}