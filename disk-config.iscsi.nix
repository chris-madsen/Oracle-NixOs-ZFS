{
  disko.devices = {
    disk = {
      boot = {
        type = "disk";
        device = "/dev/sdb";
        content = {
          type = "gpt";
          partitions = {
            ESP = {
              size = "1G";
              type = "EF00";
              content = {
                type = "filesystem";
                format = "vfat";
                mountpoint = "/boot";
                mountOptions = [ "umask=0077" ];
              };
            };
            "boot-volume" = {
              size = "100%";
              content = {
                type = "zfs";
                pool = "zroot";
              };
            };
          };
        };
      };
      data = {
        type = "disk";
        device = "/dev/sdc";
        content = {
          type = "lvm_pv";
          vg = "data_vg";
        };
      };
    };

    zpool = {
      zroot = {
        type = "zpool";
        options = {
          autoexpand = "on";
          autotrim = "on";
        };
        rootFsOptions = {
          compression = "lz4";
          acltype = "posixacl";
          xattr = "sa";
          atime = "off";
          reservation = "2G";
          mountpoint = "none";
        };
        datasets = {
          root = {
            type = "zfs_fs";
            mountpoint = "/";
            options = {
              mountpoint = "legacy";
            };
          };
        };
      };
    };

    lvm_vg = {
      data_vg = {
        type = "lvm_vg";
        lvs = {
          thinpool = {
            size = "80G";
            lvm_type = "thin-pool";
          };
          data = {
            size = "100G";
            lvm_type = "thinlv";
            pool = "thinpool";
            content = {
              type = "filesystem";
              format = "xfs";
              mountpoint = "/data";
              mountOptions = [ "defaults" "noatime" ];
            };
          };
        };
      };
    };
  };
}
