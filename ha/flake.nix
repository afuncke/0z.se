{
  description = "Custom NixOS Installer ISO for Thin Client";

  inputs = {
    # You can change this to a specific release like nixos-23.11 if preferred
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    # Add Disko input
    disko.url = "github:nix-community/disko";
    disko.inputs.nixpkgs.follows = "nixpkgs";

    # SSH authorized keys, pulled from GitHub. Not a flake; just a file the
    # lock pins. Refresh the key set with: nix flake update afuncke-keys
    afuncke-keys = {
      url = "https://github.com/afuncke.keys";
      flake = false;
    };
  };

  outputs = { self, nixpkgs, disko, afuncke-keys }: {
    nixosConfigurations = {
      ha-thinclient = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        specialArgs = { inherit afuncke-keys; };
        modules = [
          disko.nixosModules.disko
          ./configuration.nix
          ./disk-config.nix
        ];
      };
      customIso = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        specialArgs = { inherit afuncke-keys; };
        modules = [
          "${nixpkgs}/nixos/modules/installer/cd-dvd/installation-cd-minimal.nix"
          ./configuration.nix
          ./iso.nix
        ];
      };
    };
  };
}
