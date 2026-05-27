{ config, pkgs, lib, afuncke-keys, ... }:

let
  # A cursor theme whose cursors are a single fully-transparent pixel. Pointing
  # the Wayland compositor (Cage) at this hides the mouse pointer entirely,
  # which is what we want on a touchscreen kiosk.
  blankCursorTheme = pkgs.runCommand "blank-cursor-theme"
    { nativeBuildInputs = [ pkgs.imagemagick pkgs.xorg.xcursorgen ]; }
    ''
      dir=$out/share/icons/blank/cursors
      mkdir -p "$dir"
      magick -size 32x32 xc:transparent transparent.png
      echo "32 0 0 transparent.png" > cursor.cfg
      xcursorgen cursor.cfg "$dir/left_ptr"
      # Alias the cursor names apps/toolkits commonly request to the blank one.
      for name in default arrow top_left_arrow pointer hand1 hand2 xterm text \
                  watch left_ptr_watch progress; do
        ln -sf left_ptr "$dir/$name"
      done
      printf '[Icon Theme]\nName=blank\n' > "$out/share/icons/blank/index.theme"
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
    image = "ghcr.io/blakeblackshear/frigate:0.17.2";
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
    # RTSP credentials are substituted into config.yml as {FRIGATE_RTSP_PASSWORD}.
    # Put the real value in this env file on the box (created empty below) — it
    # is NOT in git. e.g.  echo 'FRIGATE_RTSP_PASSWORD=...' > the file.
    environmentFiles = [ "/var/lib/home-assistant/frigate/frigate.env" ];
  };

  # Create Frigate's directories + an empty secrets file on the data partition
  # so the first deploy doesn't fail before you've populated them.
  systemd.tmpfiles.rules = [
    "d /var/lib/home-assistant/frigate        0750 root root -"
    "d /var/lib/home-assistant/frigate/config 0750 root root -"
    "d /var/lib/home-assistant/frigate/media  0750 root root -"
    "f /var/lib/home-assistant/frigate/frigate.env 0600 root root -"
  ];

  # Don't start Frigate before its data partition is mounted (see HA above).
  systemd.services.podman-frigate.unitConfig.RequiresMountsFor =
    "/var/lib/home-assistant";

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
  # Kiosk Mode (Cage + Chromium)
  # ---------------------------------------------------------
  
  # Enable graphics support (required for Wayland/Cage)
  hardware.graphics.enable = true; 

  # Crucial for the Intel Wi-Fi and Bluetooth modules to load their proprietary firmware
  hardware.enableRedistributableFirmware = true;

  # Enable Bluetooth and its management daemon
  hardware.bluetooth.enable = true;
  hardware.bluetooth.powerOnBoot = true;

  # Cage is a Wayland kiosk compositor
  services.cage = {
    enable = true;
    user = "funcke";
    # Launch Chromium in incognito/kiosk mode pointing to the local Home Assistant
    program = "${pkgs.chromium}/bin/chromium --kiosk --start-fullscreen --no-first-run --disable-infobars --noerrdialogs http://localhost:8123";
  };

  # Hide the mouse pointer on the touchscreen by giving Cage a transparent
  # cursor theme. (The X11 `unclutter` trick does not work under Wayland.)
  systemd.services.cage-tty1.environment = {
    XCURSOR_THEME = "blank";
    XCURSOR_PATH = "${blankCursorTheme}/share/icons";
    XCURSOR_SIZE = "32";
  };

  # `nixos-rebuild switch` hangs forever in its post-activation step trying to
  # restart funcke's user session bus (dbus-broker.service) — that bus is held
  # open by the live Cage kiosk, so the restart never returns. Tell switch to
  # leave the user dbus-broker alone; its config applies on next login/reboot.
  systemd.user.services.dbus-broker = {
    restartIfChanged = false;
    reloadIfChanged = lib.mkForce false;
  };

  # Bundle the current flake into the ISO and provide an install script
  environment.systemPackages = with pkgs; [
    chromium
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
