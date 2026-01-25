# configuration.nix.tftpl
{ modulesPath, pkgs, ... }: {
  imports = [ (modulesPath + "/installer/scan/not-detected.nix") ];

  # ZRAM: ~8GB
  zramSwap = {
    enable = true;
    memoryPercent = 33;
    algorithm = "zstd";
  };

  # Garbage Collection
  nix.settings.auto-optimise-store = true;
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 7d";
  };

  # Bootloader is managed by Disko/Grub interaction
  boot.loader.grub.enable = true;
  boot.loader.grub.efiSupport = true;
  boot.loader.grub.efiInstallAsRemovable = true;
  boot.loader.grub.zfsSupport = true;
  # Ensure LVM thin-pool and ZFS are available during early boot.
  boot.initrd.kernelModules = [ "dm_mod" "dm_thin_pool" "zfs" ];
  boot.kernelModules = [ "dm_thin_pool" "zfs" ];
  services.lvm.enable = true;
  boot.supportedFilesystems = [ "zfs" ];
  boot.zfs.forceImportRoot = true;
  services.zfs.autoScrub.enable = true;

  networking.hostName = "nixos-arm-oracle";
  networking.hostId = "deadbeef";

  # Enable forwarding for containers/microservices
  boot.kernel.sysctl."net.ipv4.ip_forward" = 1;

  services.openssh.enable = true;
  users.users.ubuntu = {
    isNormalUser = true;
    extraGroups = [ "wheel" "docker" ];
    openssh.authorizedKeys.keys = [ "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQCmdX44Ocjj4HbQZtmoy3smR9YUtloYmNjhYIoVKMt/NZ3qxBlBRdcMMDVZfMyyYQwbyDYA/eLZbNwXdo87kHn1ZxbDYmfyFBItaT5yeOFu2MTkBIqMJ+a56BIGqsSm9gNjrJELPYlPtyCQxbvedpuLOIPsh5758OydVc0tx+YAMdcH6sPSHOZKSbg8wdUU12PAOXm7pJhua0GA1R+22jLLqtWpDPx9XNPV4aqa7gJ1Lstimt0bX2+STY4UTZsuyfyfu0g/jm7qGhAlc7BYMYVjJW1QbgXOrduJCyRaIaFgZbZcRjlZpdBKsu4xLFKdyaU8trP1cVNxcVuIVKK/0cFXVE/9l5E629BsCyshy+hf/4V3YbeW83Ch3u5rzdfZv2VFvvtzh7akCkq51g34v0bGZoT2Yxdzh84mAakHse/PDNB4VoZdZH9KSDY2BcugQ07X8frjrR+/2OLYeywsO0impjDzRrsBR3uSd52BloPKs6E7Uez+yJLsgudX8pcqJ8ZInXvB0kKclIG6n0vzsZRQF/9s1uL7AUy8essV+mvwAA0udetDrtVsS0o6HT6TH7PviU03Aj6xKXmr/f/+FVEOka5/tvh4d2kxaeh05QNFmUK305zHG8AGjRRxtx4UWbMXxScQETmK+w/0WXZIpJSCi2XsyfA+1Wsjt71XE7RIgw== ilja.rehemae@gmail.com" ]; 
  };
  
  # Enable Docker for your microservices
  virtualisation.docker.enable = true;

  system.stateVersion = "24.05";
}
