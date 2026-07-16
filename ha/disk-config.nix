{
  disko.devices = {
    disk = {
      # -------------------------------------
      # Drive 1: The 16GB eMMC (Root & Boot)
      # -------------------------------------
      main = {
        type = "disk";
        device = "/dev/mmcblk0";
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
                mountOptions = [ "umask=0077" ];
              };
            };
            root = {
              size = "100%";
              content = {
                type = "filesystem";
                format = "ext4";
                mountpoint = "/";
              };
            };
          };
        };
      };

      # -------------------------------------
      # Drive 2: The Larger SATA (Nix & Data)
      # -------------------------------------
      sata = {
        type = "disk";
        device = "/dev/sda";
        content = {
          type = "gpt";
          partitions = {
            nix = {
              # Give 40GB to the Nix Store (adjust as needed)
              size = "40G"; 
              content = {
                type = "filesystem";
                format = "ext4";
                mountpoint = "/nix";
              };
            };
            ha_data = {
              # General data partition: HA state, Frigate, Bento, shenas, and
              # the podman image store all live under /srv (was
              # /var/lib/home-assistant, back when HA owned the whole thing).
              size = "100%";
              content = {
                type = "filesystem";
                format = "ext4";
                mountpoint = "/srv";
              };
            };
          };
        };
      };
    };
  };
}
