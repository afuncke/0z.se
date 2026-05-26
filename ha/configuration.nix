{ config, pkgs, lib, afuncke-keys, ... }:

{
  # ---------------------------------------------------------
  # System Identity & Networking
  # ---------------------------------------------------------
  networking.hostName = "ha";
  networking.domain = "0z.se";
  networking.networkmanager.enable = true;

  # ---------------------------------------------------------
  # Bootloader (UEFI) & Kernel Modules
  # ---------------------------------------------------------
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # Essential for the system to see the eMMC and other hardware during early boot
  boot.initrd.availableKernelModules = [ "xhci_pci" "ahci" "usbhid" "usb_storage" "sd_mod" "sdhci_pci" "mmc_block" ];
  boot.initrd.kernelModules = [ ];
  boot.kernelModules = [ "kvm-intel" ];
  boot.extraModulePackages = [ ];

  # ---------------------------------------------------------
  # Home Assistant
  # ---------------------------------------------------------
  services.home-assistant = {
    enable = true;
    extraComponents = [
      # Add integrations you rely on here (e.g., "esphome", "met", "radio_browser")
      "default_config"
    ];
    config = {
      # This provides the standard default Home Assistant web UI and setup
      default_config = {};
    };
  };

  # Open the firewall for Home Assistant so you can access it from other machines
  networking.firewall.allowedTCPPorts = [ 8123 ];

  # ---------------------------------------------------------
  # Users
  # ---------------------------------------------------------
  users.users.funcke = {
    isNormalUser = true;
    description = "Kiosk User";
    extraGroups = [ "wheel" "networkmanager" "video" "audio" ];
    # You can define a password hash here or set it manually later.
    # For initial setup, an empty password or initialPassword might be useful:
    initialPassword = "";
    # Authorized keys are pulled from this user's GitHub account
    # (https://github.com/afuncke.keys), wired in as a flake input so the key
    # set is pinned in flake.lock. Refresh with: nix flake update afuncke-keys
    openssh.authorizedKeys.keyFiles = [ "${afuncke-keys}" ];
  };

  # ---------------------------------------------------------
  # SSH (remote management & deploys)
  # ---------------------------------------------------------
  services.openssh = {
    enable = true;
    settings = {
      # Key-based auth only. The kiosk user has an empty password, so password
      # and empty-password logins must stay disabled.
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      PermitRootLogin = "no";
    };
  };

  # ---------------------------------------------------------
  # Kiosk Mode (Cage + Chromium)
  # ---------------------------------------------------------
  
  # Enable graphics support (required for Wayland/Cage)
  hardware.graphics.enable = true; 

  # Crucial for the Intel Wi-Fi and Bluetooth modules to load their proprietary firmware
  hardware.enableRedistributableFirmware = true;

  # Enable Bluetooth and its management daemon
  hardware.bluetooth.enable = true;
  hardware.bluetooth.powerOnBoot = true;

  # Cage is a Wayland kiosk compositor
  services.cage = {
    enable = true;
    user = "funcke";
    # Launch Chromium in incognito/kiosk mode pointing to the local Home Assistant
    program = "${pkgs.chromium}/bin/chromium --kiosk --start-fullscreen --no-first-run --disable-infobars --noerrdialogs http://localhost:8123";
  };

  # Bundle the current flake into the ISO and provide an install script
  environment.systemPackages = with pkgs; [
    chromium
    git
    neovim
    curl
  ];

  # Allow unfree packages
  nixpkgs.config.allowUnfree = true;

  # Enable Flakes and the new 'nix' command
  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  # This value determines the NixOS release with which the system's persistent
  # state (databases, etc.) is compatible. Set it to the release you first
  # installed from and DO NOT change it on later upgrades.
  system.stateVersion = "26.05";
}
