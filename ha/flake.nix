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

    # shenas app/kiosk package. Kept separate from llm-proxy because the
    # llm-proxy flake is intentionally scoped to the standalone LLM service.
    shenas.url = "git+ssh://git@forge.sailfish-brill.ts.net/shenas/shenas.git";

    # Pinned nixpkgs solely for nats-server. nixos-unstable's nats-server 2.14.x
    # ships a broken JetStream API: every JS-API request is answered with the
    # core-protocol `+OK` instead of JSON, so JS (and therefore NATS-MQTT, which
    # requires JS) fails with `invalid character '+' looking for beginning of
    # value`. 25.05's 2.11.3 is verified working; we overlay just that one
    # package (see the overlay module below). Revisit once unstable ships a
    # fixed nats-server.
    nixpkgs-nats.url = "github:NixOS/nixpkgs/nixos-25.05";
  };

  outputs = { self, nixpkgs, disko, afuncke-keys, sops-nix, llm-proxy, shenas, nixpkgs-nats }: {
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
          # Make the shenas app/kiosk package available to configuration.nix,
          # where the OCI container is loaded from the Nix-built kiosk image.
          { _module.args.shenas = shenas; }
          # Override nats-server with the known-good 25.05 build (the unstable
          # 2.14.x JetStream API is broken — see the nixpkgs-nats input above).
          { nixpkgs.overlays = [
              (final: prev: {
                nats-server = nixpkgs-nats.legacyPackages.x86_64-linux.nats-server;
              })
            ];
          }
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
