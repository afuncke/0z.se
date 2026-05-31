# Deploy targets for the hosts in this repo.
#
# The flake is pulled fresh from GitHub (`--refresh`) rather than from the
# local tree, so your changes must be pushed before `make switch-ha`.

.PHONY: switch-ha

# SSH into the ha thinclient and activate the current main-branch config.
# `-t` allocates a TTY so sudo can prompt for funcke's password.
# The `\#` escapes Make's comment syntax; the single quotes keep the `#`
# intact for the remote shell so the flake URL parses correctly.
switch-ha:
	ssh -t ha sudo nixos-rebuild switch --refresh \
	  --flake 'github:afuncke/0z.se?dir=ha\#ha-thinclient'
