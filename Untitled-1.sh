woexport KEXEC_URL="https://github.com/nix-community/nixos-images/releases/download/nixos-24.11/nixos-kexec-installer-noninteractive-aarch64-linux.tar.gz"

mkdir -p /root/kexec && cd /root/kexec
nix shell nixpkgs#curl nixpkgs#gnutar nixpkgs#gzip nixpkgs#cpio -c bash
curl -fsSL "$KEXEC_URL" -o kexec.tar.gz
tar -xzf kexec.tar.gz

awk '
  /^kernelParams=/ {
    value = $0
    sub(/^kernelParams=/, "", value)
    if (match(value, /^"(.*)"$/, params)) value = params[1]
    if (value !~ /(^| )root=/) value = value " root=fstab"
    if (value !~ /(^| )ip=dhcp( |$)/) value = value " ip=dhcp"
    if (value !~ /(^| )rd.neednet=1( |$)/) value = value " rd.neednet=1"
    if (value !~ /(^| )rd.driver.pre=virtio_pci( |$)/) value = value " rd.driver.pre=virtio_pci"
    if (value !~ /(^| )rd.driver.pre=virtio_net( |$)/) value = value " rd.driver.pre=virtio_net"
    print "kernelParams=\"" value "\""
    next
  }
  { print }
' kexec/run > kexec/run.tmp && mv kexec/run.tmp kexec/run
chmod +x kexec/run
./kexec/run
