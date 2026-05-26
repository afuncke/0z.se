Run:

```
nix build .#nixosConfigurations.customIso.config.system.build.isoImage
```

Then write the ISO, boot it and run:

```
install-ha
```
