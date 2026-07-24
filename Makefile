# Deploy targets for the hosts in this repo.
#
# The flake is pulled fresh from GitHub (`--refresh`) rather than from the
# local tree, so your changes must be pushed before `make switch-ha`.

.PHONY: switch-ha

# Build the ha thinclient config HERE (this workstation) and deploy the result
# to ha, activating it with sudo over SSH.
#
# Why build locally instead of on ha: the config now has a flake input pulled
# over git+ssh from the shenas forge (the llm-proxy package/module). This
# workstation can authenticate to forge; ha's root cannot, so a build *on* ha
# fails to fetch that input. nixos-rebuild builds on the local host (no
# --build-host), copies the closure to --target-host, and activates there —
# ha never contacts forge. Run via `nix run` because this workstation isn't
# NixOS and has no nixos-rebuild on PATH.
#
# `--sudo` elevates via sudo on ha; funcke has passwordless sudo there
# (security.sudo.extraRules in ha/configuration.nix), so no password prompt
# is needed and the deploy runs non-interactively. The flake URL's `#` is
# single-quoted so the shell keeps it literal — no backslash escaping, since
# (unlike the old build-on-ha target) this runs nix directly with no second
# remote shell.
switch-ha:
	(cd ha; nix flake update shenas)
	git commit -m "bump shenas version" ha/flake.lock
	git push
	nix run nixpkgs#nixos-rebuild -- switch --refresh \
	  --flake 'github:afuncke/0z.se?dir=ha#ha-thinclient' \
	  --target-host ha --sudo
	ssh ha sudo systemctl restart podman-shenas-kiosk
