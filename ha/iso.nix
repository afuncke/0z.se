# ISO-only configuration. Imported by the `customIso` build *only*, so none of
# this lands on the installed `ha-thinclient` system.
{ config, pkgs, lib, ... }:

{
  # Bundle the flake into the ISO and provide the install script.
  environment.systemPackages = with pkgs; [
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

  # Copy the project directory into the ISO's /etc/nixos-config so install-ha
  # can find the flake and disk-config. (Only the live installer needs this.)
  environment.etc."nixos-config".source = ./.;
}
