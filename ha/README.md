Run:

```
nix build .#nixosConfigurations.customIso.config.system.build.isoImage
```

Then write the ISO, boot it and run:

```
install-ha
```

## Upgrading

The installed host runs `ha-thinclient` from this flake. To apply changes, commit + push from your workstation, then SSH to the box and rebuild:

```
ssh funcke@ha.0z.se
cd /path/to/0z_se/ha   # wherever the repo is checked out on the host
git pull
sudo nixos-rebuild switch --flake .#ha-thinclient
```

Or build remotely from your workstation without checking the repo out on the host:

```
nixos-rebuild switch \
  --flake .#ha-thinclient \
  --target-host funcke@ha.0z.se \
  --use-remote-sudo
```

### Bumping nixpkgs / inputs

```
nix flake update          # all inputs
nix flake update nixpkgs  # just nixpkgs
```

Commit `flake.lock`, then rebuild as above.

### Bumping Home Assistant

The HA container image is pinned in `configuration.nix` (`ghcr.io/home-assistant/home-assistant:<tag>`). Check [releases](https://github.com/home-assistant/core/releases), edit the tag, commit, push, rebuild. Podman pulls the new image on service restart; `/var/lib/home-assistant` (state, DB, UI-managed files) persists across upgrades.

### Bumping Frigate

Same pattern — Frigate's image tag is pinned in `configuration.nix`; edit, commit, rebuild.
