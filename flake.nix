{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-24.11";
    disko.url = "github:nix-community/disko/v1.11.0";
    disko.inputs.nixpkgs.follows = "nixpkgs";
    nixos-anywhere.url = "github:nix-community/nixos-anywhere";
    nixos-anywhere.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { nixpkgs, disko, nixos-anywhere, ... }@inputs:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
    in {
      packages = forAllSystems (system: {
        nixos-anywhere = nixos-anywhere.packages.${system}.default;
      });

    nixosConfigurations.default = nixpkgs.lib.nixosSystem {
      system = "aarch64-linux";
      specialArgs = { inherit inputs; };
      modules = [
        disko.nixosModules.disko
        ./configuration.nix
        ./disk-config.nix
        {
          # UEFI Bootloader
          boot.loader.grub.enable = true;
          boot.loader.grub.efiSupport = true;
          boot.loader.grub.device = "nodev";
          boot.initrd.availableKernelModules = [ "nvme" "virtio_pci" "virtio_blk" "virtio_net" ];

          # ZRAM Configuration
          # This creates a compressed swap device in RAM.
          # It prevents the system from using slow network storage for swap.
          zramSwap = {
            enable = true;
            algorithm = "zstd"; # High compression ratio, optimized for multicore ARM
            memoryPercent = 33; # ~8GB of 24GB as compressed swap
          };

          # ZFS Optimization
          # Limiting ARC to ensure ZRAM and applications have enough breathing room.
          boot.kernelParams = [ "zfs.zfs_arc_max=6442450944" ]; # 6GB limit
        }
      ];
    };
  };
}
