{
  description = "Custom NixOS Installer ISO for Thin Client";

  inputs = {
    # You can change this to a specific release like nixos-23.11 if preferred
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    # Add Disko input
    disko.url = "github:nix-community/disko";
    disko.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { self, nixpkgs, disko }: {
    nixosConfigurations = {
      ha-thinclient = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux"; 
        modules = [
          disko.nixosModules.disko
          ./configuration.nix
          ./disk-config.nix
        ];
      };
      customIso = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          "${nixpkgs}/nixos/modules/installer/cd-dvd/installation-cd-minimal.nix"
          ./configuration.nix
        ];
      };
    };
  };
}
