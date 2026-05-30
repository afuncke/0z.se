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

## Bluetooth keyboard pairing (`bluetooth.yaml`)

The kiosk's BT keyboard (MAC `7C:1E:52:0C:35:73`) is paired declaratively:
its bluetoothd `info` file — the one containing the link key — lives
encrypted in `bluetooth.yaml`, and a systemd oneshot drops it into
`/var/lib/bluetooth/<adapter>/7C:1E:52:0C:35:73/info` before `bluetooth.service`
starts. Result: a freshly-wiped host reconnects the keyboard with no human
present.

### One-time capture

1. On the `ha` host, pair the keyboard interactively:

   ```bash
   sudo bluetoothctl
   # power on
   # agent on
   # default-agent
   # scan on
   # (wait for 7C:1E:52:0C:35:73 to appear, put keyboard in pairing mode)
   # pair 7C:1E:52:0C:35:73
   # trust 7C:1E:52:0C:35:73
   # connect 7C:1E:52:0C:35:73
   # quit
   ```

2. Read back the generated `info` file (the adapter MAC is whatever
   `hciconfig` / `bluetoothctl show` reports):

   ```bash
   sudo find /var/lib/bluetooth -name info -path '*7C:1E:52:0C:35:73*' \
     -exec cat {} \;
   ```

3. Paste the entire output into `keyboard_7c1e520c3573_info` in
   `ha/secrets/bluetooth.yaml` as a YAML literal block (`|`), preserving
   indentation. Then encrypt:

   ```bash
   sops --encrypt --in-place ha/secrets/bluetooth.yaml
   ```

4. Commit. The next `nixos-rebuild switch` deploys it; on reboot the oneshot
   restores the pairing before bluetoothd starts.

### Rotating / re-pairing

If the keyboard's link key ever changes (factory reset, paired elsewhere),
repeat the capture and re-encrypt.
