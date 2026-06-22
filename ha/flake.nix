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

    # Encrypted secrets (sops-nix). The host decrypts with its SSH host key.
    sops-nix.url = "github:Mic92/sops-nix";
    sops-nix.inputs.nixpkgs.follows = "nixpkgs";

    # shenas-llm-server (the "llm-proxy"): a standalone uv2nix flake living in
    # server/llm-proxy of the shenas monorepo. Deliberately NOT wired to follow
    # our nixpkgs — its uv2nix build is pinned against its own nixpkgs (25.11),
    # so we keep that maintainer-tested combination rather than forcing it onto
    # our unstable channel.
    llm-proxy.url = "git+ssh://git@forge.sailfish-brill.ts.net/shenas/shenas.git?dir=server/llm-proxy";
  };

  outputs = { self, nixpkgs, disko, afuncke-keys, sops-nix, llm-proxy }: {
    nixosConfigurations = {
      ha-thinclient = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        specialArgs = { inherit afuncke-keys; };
        modules = [
          disko.nixosModules.disko
          sops-nix.nixosModules.sops
          # llm-proxy (shenas-llm-server): the NixOS module provides the systemd
          # service; `services.llm-proxy` is configured in configuration.nix.
          # Imported here (not in configuration.nix) because that module is
          # shared with the installer ISO below, which shouldn't run the service.
          llm-proxy.nixosModules.default
          ./configuration.nix
          ./disk-config.nix
          # Also put the `shenas-llm` CLI on PATH for on-host debugging
          # (e.g. `shenas-llm model list`); same ha-only scoping rationale.
          { environment.systemPackages =
              [ llm-proxy.packages.x86_64-linux.llm-proxy ]; }
        ];
      };
      customIso = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        specialArgs = { inherit afuncke-keys; };
        modules = [
          "${nixpkgs}/nixos/modules/installer/cd-dvd/installation-cd-minimal.nix"
          sops-nix.nixosModules.sops
          ./configuration.nix
          ./iso.nix
        ];
      };
    };
  };
}
