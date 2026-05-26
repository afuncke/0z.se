{ config, pkgs, lib, ... }:

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
    (pkgs.writeScriptBin "install-ha" ''
      #!/usr/bin/env bash
      set -e

      echo "Starting Home Assistant Thin Client Installation..."
      
      # 1. Run Disko (Partition & Format)
      echo "Partitioning and formatting disks..."
      # We use the disk-config.nix bundled in the ISO
      sudo nix run github:nix-community/disko -- --mode disko /etc/nixos-config/disk-config.nix

      # 2. Install NixOS
      echo "Installing NixOS..."
      # We point to the flake bundled in the ISO
      sudo nixos-install --flake /etc/nixos-config#ha-thinclient

      echo "Installation complete! You can now reboot."
    '')
  ];

  # This copies the project directory into the ISO's /etc/nixos-config
  environment.etc."nixos-config".source = ./.;

  # Allow unfree packages
  nixpkgs.config.allowUnfree = true;

  # Enable Flakes and the new 'nix' command
  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  # This value determines the NixOS release...
}
