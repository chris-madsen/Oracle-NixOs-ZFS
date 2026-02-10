# 1. OCI Provider configuration
provider "oci" {
  tenancy_ocid     = var.tenancy_ocid
  user_ocid        = var.user_ocid
  fingerprint      = var.fingerprint
  private_key_path = var.private_key_path
  region           = var.region
}

# Tenancy-level guardrails for Always Free (may require IAM permission to manage quotas).
resource "oci_limits_quota" "always_free_guardrails" {
  count          = var.enable_quota_guardrails ? 1 : 0
  compartment_id = var.tenancy_ocid
  name           = "always-free-guardrails"
  description    = "Safety guardrails to stay within OCI Always Free limits."
  statements = [
    "set compute-core quota standard-a1-core-count to 4 in tenancy",
    "set compute-core quota standard-a1-core-regional-count to 4 in tenancy",
    "set block-storage quota total-storage-gb to 200 in tenancy",
  ]
}

# 2. Get the list of Availability Domains (ADs)
data "oci_identity_availability_domains" "ads" {
  compartment_id = var.compartment_id
}

resource "oci_core_image" "nixos_zfs_public" {
  compartment_id = var.compartment_id
  display_name   = "nixos-zfs-public"
  launch_mode    = "PARAVIRTUALIZED"

  image_source_details {
    source_type       = "objectStorageUri"
    source_uri        = var.nixos_zfs_public_image_url
    source_image_type = "QCOW2"
  }
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

  # # Ingress: Allow Bittensor axon port for e8gateway (default 8091)
  # ingress_security_rules {
  #   protocol = "6" # TCP
  #   source   = "0.0.0.0/0"
  #   tcp_options {
  #     min = 8091
  #     max = 8091
  #   }
  # }

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

# 9. Create the Compute Instance (boot from imported custom image)
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
    source_type = "image"
    source_id   = oci_core_image.nixos_zfs_public.id
  }

  metadata = {
    ssh_authorized_keys = trimspace(file(var.ssh_public_key_path))
  }

  display_name = "NixOS_ARM_Server"

  lifecycle {
    create_before_destroy = false
    ignore_changes        = [source_details]
  }

  depends_on = [
    oci_limits_quota.always_free_guardrails,
  ]
}

# 11. Output the Public IP address
output "server_public_ip" {
  description = "Public IP of the created instance"
  value       = oci_core_instance.arm_instance.public_ip
}
