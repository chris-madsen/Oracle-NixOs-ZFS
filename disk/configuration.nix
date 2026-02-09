{ modulesPath, pkgs, ... }: {
  imports = [ (modulesPath + "/installer/scan/not-detected.nix") ];

  # --- PERFORMANCE ---
  # Отключаем ZRAM и ограничиваем ARC, чтобы инсталлер не задохнулся
  zramSwap.enable = false;
  boot.kernelParams = [ "zfs.zfs_arc_max=4294967296" ]; 

  # --- BOOTLOADER ---
  boot.loader.grub.enable = true;
  boot.loader.grub.efiSupport = true;
  boot.loader.grub.efiInstallAsRemovable = true;
  boot.loader.grub.zfsSupport = true;
  boot.loader.grub.device = "nodev";
  boot.kernelPackages = pkgs.linuxPackages_6_6;

  # --- ISCSI INITRD ---
  # Оставляем только то, что реально нужно для iSCSI
  boot.initrd.kernelModules = [ "dm_mod" "zfs" "virtio_pci" "virtio_blk" "virtio_net" "virtio_scsi" "iscsi_tcp" ];
  boot.initrd.network.enable = true;
  
  boot.kernelModules = [ "dm_mod" "zfs" "virtio_pci" "virtio_blk" "virtio_net" "virtio_scsi" ];

  # --- ISCSI PERSISTENCE ---
  # Гарантируем, что после перезагрузки диск снова подключится
  services.openiscsi = {
    enable = true;
    name = "iqn.2024-01.com.nixos:installer";
    discoverPortal = "169.254.2.3";
  };
  # ZFS должен ждать появления iSCSI устройств
  systemd.targets.zfs-import.wants = [ "iscsid.service" ];

  # --- FILESYSTEMS ---
  boot.supportedFilesystems = [ "zfs" ];
  boot.zfs.forceImportRoot = true;
  networking.hostId = "deadbeef"; 

  # --- SYSTEM ---
  nix.settings.auto-optimise-store = true;
  services.openssh.enable = true;
  
  users.users.root.openssh.authorizedKeys.keys = [ "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQCmdX44Ocjj4HbQZtmoy3smR9YUtloYmNjhYIoVKMt/NZ3qxBlBRdcMMDVZfMyyYQwbyDYA/eLZbNwXdo87kHn1ZxbDYmfyFBItaT5yeOFu2MTkBIqMJ+a56BIGqsSm9gNjrJELPYlPtyCQxbvedpuLOIPsh5758OydVc0tx+YAMdcH6sPSHOZKSbg8wdUU12PAOXm7pJhua0GA1R+22jLLqtWpDPx9XNPV4aqa7gJ1Lstimt0bX2+STY4UTZsuyfyfu0g/jm7qGhAlc7BYMYVjJW1QbgXOrduJCyRaIaFgZbZcRjlZpdBKsu4xLFKdyaU8trP1cVNxcVuIVKK/0cFXVE/9l5E629BsCyshy+hf/4V3YbeW83Ch3u5rzdfZv2VFvvtzh7akCkq51g34v0bGZoT2Yxdzh84mAakHse/PDNB4VoZdZH9KSDY2BcugQ07X8frjrR+/2OLYeywsO0impjDzRrsBR3uSd52BloPKs6E7Uez+yJLsgudX8pcqJ8ZInXvB0kKclIG6n0vzsZRQF/9s1uL7AUy8essV+mvwAA0udetDrtVsS0o6HT6TH7PviU03Aj6xKXmr/f/+FVEOka5/tvh4d2kxaeh05QNFmUK305zHG8AGjRRxtx4UWbMXxScQETmK+w/0WXZIpJSCi2XsyfA+1Wsjt71XE7RIgw== ilja.rehemae@gmail.com" ];

  system.stateVersion = "24.11";
}
