Run:

```
nix build .#nixosConfigurations.customIso.config.system.build.isoImage
```

Then write the ISO, boot it and run:

```
install-ha
```

## First-boot manual steps (not declarative)

Most of the host is declarative, but a few things can't be expressed in the
flake and must be done once, by hand, on a fresh install. Keep this list in
sync.

1. **Encrypt the sops secrets.** `frigate.yaml`, `bluetooth.yaml`, and
   `llm-proxy.yaml` ship as placeholders; fill + encrypt them (see
   `secrets/README.md`). Activation fails to decrypt until you do.
2. **`tailscale up`** once interactively to authenticate the box to the
   tailnet (needed to pull the shenas-kiosk image and to SSH in). State then
   persists in `/var/lib/tailscale`.
3. **Trust the deploy user for `make switch-ha`.** Deploys build on the
   workstation and copy the closure here; ha's nix-daemon rejects the unsigned
   closure until `funcke` is trusted. The declarative
   `nix.settings.trusted-users` handles this after the first deploy, but that
   first deploy is chicken-and-egg — bootstrap once:
   ```bash
   ssh -t ha 'sudo cp --remove-destination "$(readlink -f /etc/nix/nix.conf)" /etc/nix/nix.conf \
     && sudo chmod u+w /etc/nix/nix.conf \
     && echo "trusted-users = root funcke" | sudo tee -a /etc/nix/nix.conf \
     && sudo systemctl restart nix-daemon'
   ```
4. **Home Assistant onboarding.** Open `http://ha:8123`, create the owner
   user (HA onboarding is inherently a UI step — it can't be declared).
5. **Add the HA MQTT integration.** In the same UI session as onboarding:
   *Settings → Devices & Services → Add Integration → MQTT*, broker
   `127.0.0.1`, port `1883`, **no** username/password (NATS' MQTT listener has
   no auth). This is what makes the telemetry pipeline flow:
   `mqtt_statestream` (configured in `homeassistant/configuration.yaml`)
   publishes state changes → NATS broker → Bento → Parquet under
   `/srv/bento/nats/dt=…/`. **Without this one step the
   Parquet sink stays empty** — `mqtt_statestream` has no broker to publish to.
   HA removed broker config from YAML years ago, so it can't live in the flake;
   confirm it connected with `journalctl -u nats | grep -i 'mqtt client'`.

## Upgrading

The installed host runs `ha-thinclient` from this flake. To apply changes, commit + push from your workstation, then from the repo root:

```
make switch-ha
```

This builds the config **on the workstation** and copies the closure to ha
(`nixos-rebuild --target-host`). It must NOT build on the host: the config pulls
a `git+ssh` flake input (the `llm-proxy` package/module) from the shenas forge,
which ha's root can't authenticate to — building on ha fails to fetch it. The
workstation can. See the repo-root `Makefile` and the trusted-user note above.

### Bumping nixpkgs / inputs

```
nix flake update          # all inputs
nix flake update nixpkgs  # just nixpkgs
```

Commit `flake.lock`, then rebuild as above.

### Bumping Home Assistant

The HA container image is pinned in `configuration.nix` (`ghcr.io/home-assistant/home-assistant:<tag>`). Check [releases](https://github.com/home-assistant/core/releases), edit the tag, commit, push, rebuild. Podman pulls the new image on service restart; `/srv/home-assistant` (state, DB, UI-managed files) persists across upgrades.

### Bumping Frigate

Same pattern — Frigate's image tag is pinned in `configuration.nix`; edit, commit, rebuild.
