tenancy_ocid        = "ocid1.tenancy.oc1..aaaaaaaattopmnafstk26itnb7t3dqgqdprecczpuze2tdje4xuywzhoogqa"
user_ocid           = "ocid1.user.oc1..aaaaaaaaigvzjorynxargu7wj36xnz5edr4funcb3hec7zm55ixch57awzha"
fingerprint         = "da:37:97:55:c3:22:ad:7b:9a:7e:fd:57:a3:fa:a7:f1"
region              = "eu-stockholm-1"
compartment_id      = "ocid1.tenancy.oc1..aaaaaaaattopmnafstk26itnb7t3dqgqdprecczpuze2tdje4xuywzhoogqa" # Usually matches tenancy_ocid

private_key_path    = "/home/ilja/.oci/oci_api_key.pem"

ssh_public_key_path = "/home/ilja/.ssh/id_rsa.pub"
ssh_private_key_path = "/home/ilja/.ssh/id_rsa"
ssh_user = "root"
system_pv_size_in_gbs = 50
boot_pv_size_in_gbs = 50
data_pv_size_in_gbs = 100
boot_source_image_id = "ocid1.image.oc1.eu-stockholm-1.aaaaaaaaf3cjvwkc6foxrppyxs5qy4gli2wzwmbrlyrm3q24rlda3wmtpgma"
# Kexec bundle options (uncomment one and comment out the others as needed).
kexec_url = "local"
kexec_source_url = "https://github.com/nix-community/nixos-images/releases/download/nixos-24.11/nixos-kexec-installer-noninteractive-aarch64-linux.tar.gz"
# kexec_url = "local"
# kexec_url = "https://github.com/nix-community/nixos-images/releases/download/nixos-24.05/nixos-kexec-installer-noninteractive-aarch64-linux.tar.gz"
# kexec_url = "https://github.com/nix-community/nixos-images/releases/download/nixos-24.11/nixos-kexec-installer-noninteractive-aarch64-linux.tar.gz"
# kexec_url = "https://github.com/nix-community/nixos-images/releases/download/nixos-25.05/nixos-kexec-installer-noninteractive-aarch64-linux.tar.gz"
