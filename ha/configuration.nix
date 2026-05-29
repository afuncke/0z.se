{ config, pkgs, lib, afuncke-keys, ... }:

let
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

    # On-screen keyboard. squeekboard appears automatically whenever a client
    # requests input via the input-method-v2 protocol (Sway 1.10+ supports it).
    exec squeekboard

    # The kiosk itself: Chromium fullscreen on the local Home Assistant.
    # --enable-wayland-ime is what makes text fields request input-method-v2
    # so squeekboard pops up. Without it the OSK never shows in Chromium.
    exec chromium --kiosk --ozone-platform=wayland --enable-wayland-ime \
      --start-fullscreen --no-first-run --disable-infobars --noerrdialogs \
      http://localhost:8123
  '';
in
{
  # ---------------------------------------------------------
  # System Identity & Networking
  # ---------------------------------------------------------
  networking.hostName = "ha";
  networking.domain = "0z.se";
  networking.networkmanager.enable = true;

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

  # Create Frigate's config/media directories on the data partition so the
  # first deploy doesn't fail before they exist.
  systemd.tmpfiles.rules = [
    "d /var/lib/home-assistant/frigate        0750 root root -"
    "d /var/lib/home-assistant/frigate/config 0750 root root -"
    "d /var/lib/home-assistant/frigate/media  0750 root root -"
    # DuckDB sink written by the Bento container (see below).
    "d /var/lib/home-assistant/bento          0750 root root -"
  ];

  # Don't start Frigate before its data partition is mounted (see HA above).
  systemd.services.podman-frigate.unitConfig.RequiresMountsFor =
    "/var/lib/home-assistant";

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
    # Render the env file Frigate reads, interpolating the decrypted secrets.
    templates."frigate.env".content = ''
      FRIGATE_RTSP_USER=${config.sops.placeholder.frigate_rtsp_user}
      FRIGATE_RTSP_PASSWORD=${config.sops.placeholder.frigate_rtsp_password}
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
  # Bento (NATS -> DuckDB sink)
  # ---------------------------------------------------------
  # Bento (the warpstreamlabs stream processor) subscribes to the local NATS
  # broker and persists every message into a DuckDB file for later analysis.
  # Same pattern as HA/Frigate: pinned OCI image, host networking, config
  # bind-mounted read-only from git, durable state on the data partition.
  #
  # The image MUST be the CGO-enabled `-cgo` variant: DuckDB links a static C
  # library and is only compiled into builds with CGO (the plain image lacks
  # the duckdb SQL driver). Host networking lets Bento reach NATS on
  # 127.0.0.1:4222 (loopback, so no firewall change needed). The DuckDB file is
  # written to /data -> /var/lib/home-assistant/bento on the data partition.
  virtualisation.oci-containers.containers.bento = {
    image = "ghcr.io/warpstreamlabs/bento:1.18.0-cgo";
    cmd = [ "-c" "/bento.yaml" ];
    extraOptions = [ "--network=host" ];
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
    after = [ "nats.service" ];
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

  # `nixos-rebuild switch` hangs forever in its post-activation step trying to
  # restart funcke's user session bus (dbus-broker.service) — that bus is held
  # open by the live graphical session, so the restart never returns. Tell
  # switch to leave the user dbus-broker alone; its config applies on next
  # login/reboot.
  systemd.user.services.dbus-broker = {
    restartIfChanged = false;
    reloadIfChanged = lib.mkForce false;
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

  # This value determines the NixOS release with which the system's persistent
  # state (databases, etc.) is compatible. Set it to the release you first
  # installed from and DO NOT change it on later upgrades.
  system.stateVersion = "26.05";
}
