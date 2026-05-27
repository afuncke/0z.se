# Secrets (sops-nix)

Secrets are committed **encrypted** here and decrypted on the `ha` host at
activation using its SSH host key. Plaintext never enters git or the Nix store.

## One-time setup

1. **Create your admin age key** (on your workstation):

   ```bash
   mkdir -p ~/.config/sops/age
   age-keygen -o ~/.config/sops/age/keys.txt   # prints "Public key: age1..."
   ```

2. **Get the host's age public key** (derived from its SSH host key):

   ```bash
   ssh funcke@ha 'cat /etc/ssh/ssh_host_ed25519_key.pub' | nix run nixpkgs#ssh-to-age
   ```

3. Put both public keys into `../../.sops.yaml` (replace the two placeholders).

## Encrypt the secret

From the repo root, fill in real values then encrypt in place:

```bash
$EDITOR ha/secrets/frigate.yaml          # set frigate_rtsp_user / _password
sops --encrypt --in-place ha/secrets/frigate.yaml
```

Edit later with: `sops ha/secrets/frigate.yaml` (decrypts to your editor,
re-encrypts on save).

## After it's real

Flip `sops.validateSopsFiles` back to `true` in `../configuration.nix` to get
build-time validation that the referenced keys exist.
