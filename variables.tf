variable "tenancy_ocid" {}
variable "user_ocid" {}
variable "fingerprint" {}
variable "private_key_path" {}
variable "region" {}
variable "compartment_id" {}
variable "ssh_public_key_path" {}
variable "ssh_private_key_path" {}
variable "ssh_user" {
  default = "root"
}
variable "system_pv_size_in_gbs" {}
variable "boot_pv_size_in_gbs" {}
variable "data_pv_size_in_gbs" {}
variable "boot_source_image_id" {
  default = ""
}
variable "kexec_url" {}
variable "kexec_source_url" {}
variable "create_volume_snapshots" {
  default = false
}
