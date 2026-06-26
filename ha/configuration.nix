{ config, pkgs, lib, afuncke-keys, shenas, ... }:

let
  shenasHomeAssistantSourcePlugin = pkgs.runCommand "shenas-source-homeassistant-plugin" { } ''
    plugin_src=${shenas.outPath}/plugins/sources/homeassistant
    mkdir -p "$out/shenas_sources"
    cp -r "$plugin_src/shenas_sources/homeassistant" "$out/shenas_sources/homeassistant"

    dist_info="$out/shenas_source_homeassistant-0.1.0.dist-info"
    mkdir -p "$dist_info"
    cat > "$dist_info/METADATA" <<'EOF'
Metadata-Version: 2.1
Name: shenas-source-homeassistant
Version: 0.1.0
Summary: Home Assistant landing-zone parquet connector for shenas
Requires-Python: >=3.11
Requires-Dist: duckdb>=1.2.0
Requires-Dist: shenas-source-core
EOF
    cat > "$dist_info/WHEEL" <<'EOF'
Wheel-Version: 1.0
Generator: nix
Root-Is-Purelib: true
Tag: py3-none-any
EOF
    cat > "$dist_info/entry_points.txt" <<'EOF'
[shenas.sources]
homeassistant = shenas_sources.homeassistant.source:HomeAssistantSource
EOF
  '';

  # Sway kiosk config: black background, no decorations, native cursor hiding,
  # squeekboard for the on-screen keyboard (auto-shows on text-input focus via
  # input-method-v2), and Chromium fullscreen on HA.
  swayKioskConfig = pkgs.writeText "sway-kiosk.conf" ''
    # Cursor — replaces the Cage-era transparent-cursor-theme workaround.
    seat * hide_cursor 1000
    seat * hide_cursor when-typing enable

    # Strip every chrome a kiosk doesn't need.
    default_border none
    default_floating_border none
    titlebar_padding 0
    font pango:monospace 0
    output * bg #000000 solid_color
    focus_follows_mouse no

    # On-screen keyboard. squeekboard runs as a user systemd service (defined
    # below) so it gets logs, restart, and proper session DBus activation —
    # `exec squeekboard` from here was silently failing in greetd's minimal
    # session. Once running, squeekboard auto-shows whenever a client requests
    # input via text-input-v3 / input-method-v2.
    exec systemctl --user start squeekboard.service

    # The kiosk itself: Chromium fullscreen on the local Home Assistant.
    # --enable-wayland-ime is what makes text fields request input-method-v2
    # so squeekboard pops up. Without it the OSK never shows in Chromium.
    exec chromium --kiosk --ozone-platform=wayland --enable-wayland-ime \
      --start-fullscreen --no-first-run --disable-infobars --noerrdialogs \
      http://localhost:7280
  '';
in
{
  # ---------------------------------------------------------
  # System Identity & Networking
  # ---------------------------------------------------------
  networking.hostName = "ha";
  networking.domain = "0z.se";
  networking.networkmanager.enable = true;

  # System timezone. Also materializes /etc/localtime, which the Frigate
  # container bind-mounts read-only (see the Frigate block below) — without a
  # timezone set, /etc/localtime doesn't exist and podman fails to start
  # Frigate with `statfs /etc/localtime: no such file or directory`. Matches the
  # TZ already used for the HA and Bento containers.
  time.timeZone = "Europe/Stockholm";

  # Tailscale: needed so this host can pull podman images from
  # `registry.sailfish-brill.ts.net` (the shenas-kiosk image lives there) and
  # so we can SSH in over the tailnet. NixOS just runs the daemon and opens
  # the tailnet interface in the firewall — `tailscale up` still has to be
  # run once interactively on the host to authenticate against the tailnet
  # (browser flow). After that, state in /var/lib/tailscale persists across
  # reboots.
  services.tailscale.enable = true;

  # ---------------------------------------------------------
  # Bootloader (UEFI) & Kernel Modules
  # ---------------------------------------------------------
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # Essential for the system to see the eMMC and other hardware during early boot
  boot.initrd.availableKernelModules = [ "xhci_pci" "ahci" "usbhid" "usb_storage" "sd_mod" "sdhci_pci" "mmc_block" ];
  boot.initrd.kernelModules = [ ];
  boot.kernelModules = [ "kvm-intel" ];
  boot.extraModulePackages = [ ];

  # ---------------------------------------------------------
  # Home Assistant
  # ---------------------------------------------------------
  # Home Assistant runs as the official OCI container (installation type
  # "Container" — the supported, always-latest method) via Podman.
  #
  # Config split:
  #   - Writable, persistent /config  -> /var/lib/home-assistant on the data
  #     partition. Holds HA-generated state: .storage/, the SQLite DB, logs,
  #     secrets.yaml, and UI-managed files (automations.yaml, scripts.yaml,
  #     scenes.yaml). NOT tracked in git.
  #   - Hand-authored configuration.yaml -> bind-mounted read-only from this
  #     repo (./homeassistant/configuration.yaml). Tracked in git; changes
  #     apply via push -> nixos-rebuild. It !includes the writable UI files,
  #     which resolve relative to /config on the machine.
  virtualisation.podman.enable = true;
  virtualisation.oci-containers.backend = "podman";
  virtualisation.oci-containers.containers.homeassistant = {
    # Pinned to a specific release for reproducible deploys. Bump deliberately:
    # check https://github.com/home-assistant/core/releases, update the tag,
    # then push + nixos-rebuild.
    image = "ghcr.io/home-assistant/home-assistant:2026.5.4";
    # Host networking is needed for device discovery (mDNS/SSDP) and many
    # integrations; it also makes HA listen on host :8123 for the kiosk.
    extraOptions = [ "--network=host" "--privileged" ];
    volumes = [
      "/var/lib/home-assistant:/config"
      "${./homeassistant/configuration.yaml}:/config/configuration.yaml:ro"
      "/run/dbus:/run/dbus:ro"
    ];
    environment.TZ = "Europe/Stockholm";
  };

  # Robustness for the HA container service: start only after the data
  # partition is mounted, and fail loudly if it isn't — never silently write
  # HA's DB into the bare mountpoint on the eMMC root and have the partition
  # shadow it later. (oci-containers already sets TimeoutStartSec=0, so a slow
  # first image pull won't time out.)
  systemd.services.podman-homeassistant.unitConfig.RequiresMountsFor =
    "/var/lib/home-assistant";

  # HACS (Home Assistant Community Store) — community integrations/cards/themes.
  # HACS lives in /config/custom_components (runtime state, not git) and updates
  # itself in place via the UI, so we don't try to manage it declaratively.
  # Instead we *seed* a pinned release into custom_components/hacs once, only if
  # it's absent, then let HACS self-update. This keeps a fresh box reproducible
  # (it comes up with a known-good HACS) without fighting HACS's own updater.
  #
  # The pinned hacs.zip is fetched + hash-verified at build; stripRoot=false so
  # the archive's files (manifest.json, __init__.py, ...) land directly as the
  # component dir contents. Bump by changing the version + hash here.
  #
  # NOTE: after deploy you must RESTART Home Assistant once for it to discover
  # the new component, then finish setup in the UI:
  #   Settings -> Devices & Services -> Add Integration -> HACS  (GitHub device
  #   auth). HACS requires the HA "default_config" / frontend, both already on.
  systemd.services.hacs-seed =
    let
      hacs = pkgs.fetchzip {
        url = "https://github.com/hacs/integration/releases/download/2.0.5/hacs.zip";
        hash = "sha256-iMomioxH7Iydy+bzJDbZxt6BX31UkCvqhXrxYFQV8Gw=";
        stripRoot = false;
      };
    in
    {
      description = "Seed HACS into Home Assistant custom_components (if absent)";
      wantedBy = [ "multi-user.target" ];
      before = [ "podman-homeassistant.service" ];
      unitConfig.RequiresMountsFor = "/var/lib/home-assistant";
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      # HA runs as uid 286 and keeps /config mode 0700, so the seeded files must
      # be owned by 286 and writable (nix store is read-only) for HACS to update.
      script = ''
        dest=/var/lib/home-assistant/custom_components/hacs
        if [ -e "$dest/manifest.json" ]; then
          echo "HACS already present at $dest; leaving it (HACS self-updates)."
          exit 0
        fi
        ${pkgs.coreutils}/bin/mkdir -p "$dest"
        ${pkgs.coreutils}/bin/cp -rT ${hacs} "$dest"
        ${pkgs.coreutils}/bin/chmod -R u+w "$dest"
        ${pkgs.coreutils}/bin/chown -R 286:286 \
          /var/lib/home-assistant/custom_components
      '';
    };

  # Open the firewall: 8123 = Home Assistant, 8971 = Frigate (authenticated UI).
  # Frigate's internal API (5000) and go2rtc (8554/8555) stay closed; open the
  # latter only if you want WebRTC/RTSP live view from other machines.
  networking.firewall.allowedTCPPorts = [ 8123 8971 ];

  # ---------------------------------------------------------
  # Frigate NVR (OCI container, Intel iGPU / OpenVINO detection)
  # ---------------------------------------------------------
  # Same pattern as HA: pinned image; writable /config (frigate.db, model
  # cache, logs) and recordings live on the data partition (the only place
  # with real space); config.yml is bind-mounted read-only from git. Object
  # detection runs on the Intel iGPU via OpenVINO; the iGPU also does VAAPI
  # decode. Frigate publishes events to the local NATS MQTT broker.
  virtualisation.oci-containers.containers.frigate = {
    image = "ghcr.io/blakeblackshear/frigate:0.17.1";
    extraOptions = [
      "--network=host"               # go2rtc/WebRTC + camera discovery; UI on :8971/:5000
      "--device=/dev/dri/renderD128" # Intel iGPU: OpenVINO detection + VAAPI decode
      "--shm-size=256m"              # raise as you add cameras (Frigate logs the size it needs)
      "--tmpfs=/tmp/cache:size=1g"   # Frigate clip cache
    ];
    volumes = [
      "/var/lib/home-assistant/frigate/config:/config"
      "/var/lib/home-assistant/frigate/media:/media/frigate"
      "${./frigate/config.yml}:/config/config.yml:ro"
      "/etc/localtime:/etc/localtime:ro"
    ];
    # RTSP creds (FRIGATE_RTSP_USER/PASSWORD, substituted into config.yml) come
    # from a sops-rendered env file — encrypted in git, decrypted on the host.
    # See the sops block below.
    environmentFiles = [ config.sops.templates."frigate.env".path ];
  };

  # Create Frigate's, Bento's, and shenas' bind-mount source dirs on the data partition
  # before the containers start. We deliberately do NOT use systemd.tmpfiles:
  # the HA container keeps the partition root (/var/lib/home-assistant) owned by
  # its own (orphan) uid, mode 0700, and systemd-tmpfiles refuses to create a
  # root-owned directory under a non-root-owned parent ("Detected unsafe path
  # transition ... during canonicalization") as a symlink-attack guard. The
  # dirs were therefore never created and Frigate died at startup with
  #   statfs /var/lib/home-assistant/frigate/config: no such file or directory
  # A plain root `mkdir` has no such guard. RequiresMountsFor pins this after
  # the data partition is mounted, so we never write into the bare eMMC
  # mountpoint and have the partition shadow it later.
  systemd.services.home-assistant-data-dirs = {
    description = "Create Frigate/Bento/shenas bind-mount dirs on the data partition";
    unitConfig.RequiresMountsFor = "/var/lib/home-assistant";
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${pkgs.coreutils}/bin/mkdir -p"
        + " /var/lib/home-assistant/frigate/config"
        + " /var/lib/home-assistant/frigate/media"
        + " /var/lib/home-assistant/bento"
        + " /var/lib/home-assistant/shenas";
    };
  };

  # Don't start Frigate before its data partition is mounted (see HA above) or
  # before its bind-mount dirs exist.
  systemd.services.podman-frigate = {
    unitConfig.RequiresMountsFor = "/var/lib/home-assistant";
    after = [ "home-assistant-data-dirs.service" ];
    requires = [ "home-assistant-data-dirs.service" ];
  };

  # ---------------------------------------------------------
  # Secrets (sops-nix)
  # ---------------------------------------------------------
  # Secrets are committed encrypted in ./secrets/*.yaml and decrypted on the
  # host at activation using its SSH host key (no separate key to manage).
  # Edit with:  sops secrets/frigate.yaml   (recipients set in ./.sops.yaml)
  sops = {
    defaultSopsFile = ./secrets/frigate.yaml;
    age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];
    # Re-enable once the real encrypted secrets/frigate.yaml is committed; left
    # off so the repo builds with the placeholder before you've encrypted it.
    validateSopsFiles = false;
    secrets.frigate_rtsp_user = { };
    secrets.frigate_rtsp_password = { };
    # Bluetooth keyboard pairing record (the bluetoothd `info` file, link key
    # and all). Consumed by systemd.services.bluetooth-keyboard-pairing above.
    secrets.bluetooth_keyboard_info = {
      sopsFile = ./secrets/bluetooth.yaml;
      key = "keyboard_7c1e520c3573_info";
    };
    # Render the env file Frigate reads, interpolating the decrypted secrets.
    templates."frigate.env".content = ''
      FRIGATE_RTSP_USER=${config.sops.placeholder.frigate_rtsp_user}
      FRIGATE_RTSP_PASSWORD=${config.sops.placeholder.frigate_rtsp_password}
    '';
    # llm-proxy's Claude credential. Lives in its own encrypted file; fill it
    # with `sops ha/secrets/llm-proxy.yaml` (key: llm_anthropic_api_key).
    secrets.llm_anthropic_api_key = { sopsFile = ./secrets/llm-proxy.yaml; };
    # Env file consumed by services.llm-proxy.environmentFile.
    templates."llm-proxy.env".content = ''
      ANTHROPIC_API_KEY=${config.sops.placeholder.llm_anthropic_api_key}
    '';
  };

  # ---------------------------------------------------------
  # NATS (MQTT broker for Home Assistant)
  # ---------------------------------------------------------
  # NATS' built-in MQTT support lets it act as the broker HA publishes to.
  # MQTT requires JetStream (it persists MQTT sessions there), so jetstream
  # must be enabled. The MQTT listener is bound to localhost only: the
  # host-networked HA container reaches it at 127.0.0.1:1883, and we don't
  # want the broker exposed on the LAN. The NATS client port (4222) likewise
  # stays closed in the firewall; open it only if remote NATS clients need it.
  services.nats = {
    enable = true;
    jetstream = true;
    serverName = "ha-nats";
    settings = {
      mqtt.listen = "127.0.0.1:1883";
    };
  };

  # ---------------------------------------------------------
  # Bento (NATS -> Parquet sink)
  # ---------------------------------------------------------
  # Bento (the warpstreamlabs stream processor) subscribes to the local NATS
  # broker and persists every message as time-partitioned Parquet files for
  # later analysis with DuckDB. Same pattern as HA/Frigate: pinned OCI image,
  # host networking, config bind-mounted read-only from git, durable state on
  # the data partition.
  #
  # Parquet encoding is pure Go, so the plain image is fine — no CGO/`-cgo`
  # variant needed (that was only required for the old DuckDB SQL driver). Host
  # networking lets Bento reach NATS on 127.0.0.1:4222 (loopback, so no firewall
  # change needed). Files land under /data/nats/dt=YYYY-MM-DD/ ->
  # /var/lib/home-assistant/bento on the data partition. Because the files are
  # immutable and never held open, DuckDB can query them at any time without the
  # single-writer lock contention a live .duckdb file would impose:
  #   SELECT * FROM read_parquet('/var/lib/home-assistant/bento/nats/**/*.parquet',
  #                              hive_partitioning=true);
  virtualisation.oci-containers.containers.bento = {
    image = "ghcr.io/warpstreamlabs/bento:1.18.0";
    cmd = [ "-c" "/bento.yaml" ];
    # Run as root (like Frigate) so Bento can create /data/nats/ under the
    # root-owned /var/lib/home-assistant/bento. The image otherwise runs as
    # `nobody`, which can't write that dir — `mkdir /data/nats: permission
    # denied`. Running as root is version-independent (no hardcoded image uid).
    extraOptions = [ "--network=host" "--user" "0:0" ];
    volumes = [
      "${./bento/config.yaml}:/bento.yaml:ro"
      "/var/lib/home-assistant/bento:/data"
    ];
    environment.TZ = "Europe/Stockholm";
  };

  # Don't start Bento before its data partition is mounted, and not before NATS
  # is up (Bento retries, but this avoids noisy startup failures).
  systemd.services.podman-bento = {
    unitConfig.RequiresMountsFor = "/var/lib/home-assistant";
    after = [ "nats.service" "home-assistant-data-dirs.service" ];
    requires = [ "home-assistant-data-dirs.service" ];
  };

  # ---------------------------------------------------------
  # llm-proxy (shenas-llm-server)
  # ---------------------------------------------------------
  # Standalone LLM inference + metering service from the shenas monorepo,
  # packaged + moduled in its own flake (server/llm-proxy). The systemd unit
  # comes from llm-proxy.nixosModules.default (imported in flake.nix); here we
  # set site policy only.
  #
  # Exposure: bound to localhost — the only consumer is on-host (the
  # host-networked shenas-kiosk container reaches it at 127.0.0.1:8500), so the
  # firewall stays closed and auth is left off (no LLM_API_KEY). The DuckDB
  # metering/cache store persists under /var/lib/llm-proxy (StateDirectory in
  # the module). ANTHROPIC_API_KEY — the one real secret — is injected via the
  # sops-rendered env file below.
  services.llm-proxy = {
    enable = true;
    host = "127.0.0.1";
    port = 8500;
    environmentFile = config.sops.templates."llm-proxy.env".path;
  };

  # ---------------------------------------------------------
  # shenas-kiosk (OCI container)
  # ---------------------------------------------------------
  # Nix-built shenas kiosk image. The app now reconciles desired plugin state
  # at startup from SHENAS_DESIRED_PLUGINS_FILE; packages must still be baked
  # into the image for that reconciliation to enable them.
  virtualisation.oci-containers.containers.shenas-kiosk = {
    image = "shenas-kiosk-nix:latest";
    imageFile = shenas.packages.x86_64-linux.kiosk-image;
    extraOptions = [ "--network=host" ];
    volumes = [
      "${./shenas/desired-plugins.json}:/etc/shenas/desired-plugins.json:ro"
      "/var/lib/home-assistant/shenas:/data"
    ];
    environment = {
      PYTHONPATH = "${shenasHomeAssistantSourcePlugin}";
      SHENAS_DESIRED_PLUGINS_FILE = "/etc/shenas/desired-plugins.json";
    };
  };

  systemd.services.podman-shenas-kiosk = {
    unitConfig.RequiresMountsFor = "/var/lib/home-assistant";
    after = [ "home-assistant-data-dirs.service" ];
    requires = [ "home-assistant-data-dirs.service" ];
  };

  # ---------------------------------------------------------
  # Users
  # ---------------------------------------------------------
  users.users.funcke = {
    isNormalUser = true;
    description = "Kiosk User";
    extraGroups = [ "wheel" "networkmanager" "video" "audio" ];
    # You can define a password hash here or set it manually later.
    # For initial setup, an empty password or initialPassword might be useful:
    initialPassword = "";
    # Authorized keys are pulled from this user's GitHub account
    # (https://github.com/afuncke.keys), wired in as a flake input so the key
    # set is pinned in flake.lock. Refresh with: nix flake update afuncke-keys
    openssh.authorizedKeys.keyFiles = [ "${afuncke-keys}" ];
  };

  # Temporary ("for now"): passwordless sudo for funcke so deploys and on-box
  # debugging don't need an interactive TTY password prompt. Scoped to this user
  # via extraRules rather than security.sudo.wheelNeedsPassword, so it doesn't
  # blanket the whole wheel group. Revisit once debugging settles.
  security.sudo.extraRules = [{
    users = [ "funcke" ];
    commands = [{ command = "ALL"; options = [ "NOPASSWD" ]; }];
  }];

  # ---------------------------------------------------------
  # SSH (remote management & deploys)
  # ---------------------------------------------------------
  services.openssh = {
    enable = true;
    settings = {
      # Key-based auth only. The kiosk user has an empty password, so password
      # and empty-password logins must stay disabled.
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      PermitRootLogin = "no";
    };
  };

  # ---------------------------------------------------------
  # Kiosk Mode (Sway + Chromium + squeekboard OSK)
  # ---------------------------------------------------------
  # Replaced Cage with Sway because Cage lacks layer-shell + input-method-v2,
  # which any on-screen keyboard needs to render and to auto-show on focus.
  # Sway also natively hides the cursor, so the transparent-cursor-theme hack
  # is gone.

  # Graphics + firmware (needed for the iGPU under Wayland + Wi-Fi/Bluetooth).
  hardware.graphics.enable = true;
  hardware.enableRedistributableFirmware = true;
  hardware.bluetooth.enable = true;
  hardware.bluetooth.powerOnBoot = true;

  # Declarative pairing for the kiosk's Bluetooth keyboard
  # (7C:1E:52:0C:35:73). bluetoothd persists pairings under
  # /var/lib/bluetooth/<adapter>/<device>/info — that file contains the link
  # key, so it's a secret. We ship it via sops and drop it into place before
  # bluetoothd starts, so a freshly-wiped host reconnects the keyboard with no
  # human present. One-time capture flow is in secrets/README.md.
  systemd.services.bluetooth-keyboard-pairing = {
    description = "Restore declarative Bluetooth keyboard pairing";
    wantedBy = [ "bluetooth.service" ];
    before = [ "bluetooth.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      set -eu
      # Adapter MAC is the BT controller soldered into this thinclient. If the
      # board is ever replaced, update this and re-pair.
      adapter_mac="F4:B3:01:1E:C4:62"
      device_mac="7C:1E:52:0C:35:73"
      device_dir="/var/lib/bluetooth/$adapter_mac/$device_mac"
      install -d -m 0700 -o root -g root "/var/lib/bluetooth/$adapter_mac"
      install -d -m 0700 -o root -g root "$device_dir"
      install -m 0600 -o root -g root \
        ${config.sops.secrets.bluetooth_keyboard_info.path} \
        "$device_dir/info"
      # Deliberately do NOT `systemctl restart bluetooth.service` here: this
      # unit is Before=bluetooth.service, so a restart from inside the unit
      # deadlocks (bluetooth.service waits for us to exit, we wait for it to
      # restart). On a fresh boot the Before= ordering is enough. On a
      # nixos-rebuild switch where the file changes but bluetoothd isn't
      # restarted, the new pairing applies after the next reboot — or run
      # `sudo systemctl restart bluetooth` manually if you don't want to wait.
    '';
  };

  programs.sway = {
    enable = true;
    wrapperFeatures.gtk = true;   # GTK apps (e.g. squeekboard) launched from the wrapper
  };

  # Autologin funcke straight into the Sway kiosk session — no prompt, no DM.
  services.greetd = {
    enable = true;
    settings.default_session = {
      user = "funcke";
      command = "${pkgs.sway}/bin/sway --config ${swayKioskConfig}";
    };
  };

  # Order greetd after shenas-kiosk so Chromium doesn't race the container and
  # render a connection-refused error page. `Wants=` (not `Requires=`) keeps
  # this soft: if the container fails, the kiosk still comes up (showing an
  # error page) rather than leaving the display blank.
  # Caveat: this only waits for podman to *start* the container, not for the
  # HTTP server inside it to be listening on :7280. Tighten with a port-wait
  # oneshot if first-pull/cold-start races still happen.
  systemd.services.greetd = {
    after = [ "podman-shenas-kiosk.service" ];
    wants = [ "podman-shenas-kiosk.service" ];
  };

  # `nixos-rebuild switch` hangs forever in its post-activation step trying to
  # restart funcke's user session bus (dbus-broker.service) — that bus is held
  # open by the live graphical session, so the restart never returns. Tell
  # switch to leave the user dbus-broker alone; its config applies on next
  # login/reboot.
  systemd.user.services.dbus-broker = {
    restartIfChanged = false;
    reloadIfChanged = lib.mkForce false;
  };

  # On-screen keyboard as a user service. Started explicitly by the sway
  # kiosk config (see swayKioskConfig above) rather than via
  # sway-session.target, which greetd's minimal session doesn't reliably
  # reach. Restart=on-failure so a crash doesn't silently leave the kiosk
  # without an OSK.
  systemd.user.services.squeekboard = {
    description = "On-screen keyboard (squeekboard)";
    serviceConfig = {
      ExecStart = "${pkgs.squeekboard}/bin/squeekboard";
      Restart = "on-failure";
    };
  };

  environment.systemPackages = with pkgs; [
    chromium
    squeekboard      # the on-screen keyboard Sway auto-shows on text input
    git
    neovim
    curl
  ];

  # Allow unfree packages
  nixpkgs.config.allowUnfree = true;

  # Enable Flakes and the new 'nix' command
  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  # Trust funcke for store operations so `make switch-ha` can build the config
  # on the workstation and copy the (unsigned) closure here. Without this, ha's
  # nix-daemon rejects unsigned paths pushed by a non-trusted user. We build off
  # the host because the config now pulls a git+ssh flake input from the shenas
  # forge, which ha's root can't authenticate to. See the repo-root Makefile.
  nix.settings.trusted-users = [ "funcke" ];

  # This value determines the NixOS release with which the system's persistent
  # state (databases, etc.) is compatible. Set it to the release you first
  # installed from and DO NOT change it on later upgrades.
  system.stateVersion = "26.05";
}
