# configuration.minimal.nix.tftpl
{ config, pkgs, ... }:
{
  imports = [ ./hardware-configuration.nix ];

  networking.hostName = "nixos-minimal";
  networking.hostId = "deadbeef";
  networking.useDHCP = true;

  services.openssh.enable = true;
  services.openssh.settings.PasswordAuthentication = false;

  users.users.root.openssh.authorizedKeys.keys = [ "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQCmdX44Ocjj4HbQZtmoy3smR9YUtloYmNjhYIoVKMt/NZ3qxBlBRdcMMDVZfMyyYQwbyDYA/eLZbNwXdo87kHn1ZxbDYmfyFBItaT5yeOFu2MTkBIqMJ+a56BIGqsSm9gNjrJELPYlPtyCQxbvedpuLOIPsh5758OydVc0tx+YAMdcH6sPSHOZKSbg8wdUU12PAOXm7pJhua0GA1R+22jLLqtWpDPx9XNPV4aqa7gJ1Lstimt0bX2+STY4UTZsuyfyfu0g/jm7qGhAlc7BYMYVjJW1QbgXOrduJCyRaIaFgZbZcRjlZpdBKsu4xLFKdyaU8trP1cVNxcVuIVKK/0cFXVE/9l5E629BsCyshy+hf/4V3YbeW83Ch3u5rzdfZv2VFvvtzh7akCkq51g34v0bGZoT2Yxdzh84mAakHse/PDNB4VoZdZH9KSDY2BcugQ07X8frjrR+/2OLYeywsO0impjDzRrsBR3uSd52BloPKs6E7Uez+yJLsgudX8pcqJ8ZInXvB0kKclIG6n0vzsZRQF/9s1uL7AUy8essV+mvwAA0udetDrtVsS0o6HT6TH7PviU03Aj6xKXmr/f/+FVEOka5/tvh4d2kxaeh05QNFmUK305zHG8AGjRRxtx4UWbMXxScQETmK+w/0WXZIpJSCi2XsyfA+1Wsjt71XE7RIgw== ilja.rehemae@gmail.com" ];

  boot.loader.grub.enable = true;
  boot.loader.grub.efiSupport = true;
  boot.loader.grub.device = "nodev";
  boot.loader.grub.copyKernels = false;
  boot.loader.grub.configurationLimit = 1;
  boot.loader.efi.efiSysMountPoint = "/boot";
  boot.loader.grub.extraEntries = ''
    menuentry "NixOS-ZFS (sdb1)" {
      insmod part_gpt
      insmod fat
      search --set=bootzfs --label NIXBOOT
      configfile ($bootzfs)/grub/grub.cfg
    }
  '';
  boot.loader.grub.default = "NixOS-ZFS (sdb1)";
  boot.supportedFilesystems = [ "zfs" ];
  boot.initrd.kernelModules = [ "zfs" "dm_mod" "dm_thin_pool" ];
  boot.kernelModules = [ "zfs" "dm_thin_pool" ];
  services.lvm.enable = true;

  system.stateVersion = "24.05";
}
