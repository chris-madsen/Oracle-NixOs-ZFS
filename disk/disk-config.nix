{
  disko.devices = {
    disk = {
      sdb = {
        type = "disk";
        device = "/dev/sdb";
        content = {
          type = "gpt";
          partitions = {
            ESP = {
              size = "512M";
              type = "EF00";
              content = {
                type = "filesystem";
                format = "vfat";
                mountpoint = "/boot";
              };
            };

            zfs = {
              size = "100%";
              content = {
                type = "zfs";
                pool = "zroot";
              };
            };
          };
        };
      };
    };

    zpool = {
      zroot = {
        type = "zpool";

        # pool-level defaults: safe/common settings
        rootFsOptions = {
          compression = "lz4";
          "com.sun:auto-snapshot" = "false";
          acltype = "posixacl";
          xattr = "sa";
          atime = "off";

          # keep pool itself unmounted
          mountpoint = "none";

          # keep sync conservative at pool/root; do sync=disabled only on /nix and /tmp datasets
          sync = "standard";

          reservation = "1G";
        };

        mountpoint = null;

        options = {
          ashift = "12";
          autoexpand = "on";
          autotrim = "on";
        };

        datasets = {
          rt = {
            type = "zfs_fs";
            mountpoint = "/";
            options = {
              mountpoint = "legacy";
              sync = "disabled";
            };
          };
          root = {
            type = "zfs_fs";
            mountpoint = "/root";
            options = {
              mountpoint = "legacy";
              sync = "standard";
            };
          };
          nix = {
            type = "zfs_fs";
            mountpoint = "/nix";
            options = {
              mountpoint = "legacy";
              atime = "off";
              recordsize = "64K";
              redundant_metadata = "most";
              sync = "disabled";
            };
          };

          tmp = {
            type = "zfs_fs";
            mountpoint = "/tmp";
            options = {
              mountpoint = "legacy";
              atime = "off";
              recordsize = "16K";
              sync = "disabled";
            };
          };
        };
      };
    };
  };
}
