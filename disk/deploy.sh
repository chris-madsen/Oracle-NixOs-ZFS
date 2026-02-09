#!/usr/bin/env bash
# ./deploy.sh
set -e

if [ ! -f "./nixos-kexec-bootstrap.sh" ]; then
    echo "ERROR: nixos-kexec-bootstrap.sh not found."
    exit 1
fi

# Создаем flake.nix на лету, так как он тривиален
cat <<EOF > /root/installer/flake.nix
{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-24.11";
    disko.url = "github:nix-community/disko/v1.11.0";
    disko.inputs.nixpkgs.follows = "nixpkgs";
  };
  outputs = { nixpkgs, disko, ... }@inputs: {
    nixosConfigurations.default = nixpkgs.lib.nixosSystem {
      system = "aarch64-linux";
      specialArgs = { inherit inputs; };
      modules = [ disko.nixosModules.disko ./configuration.nix ./disk-config.nix ];
    };
  };
}
EOF

echo ">>> Payload prepared in /root/installer"
echo ">>> Launching Kexec..."

# --no-inject мы НЕ передаем (по умолчанию on)
# --root-fstab передаем, чтобы добавить rd.neednet=1
./nixos-kexec-bootstrap.sh --root-fstab