#!/usr/bin/env bash
#
# One-time migration for the ha thinclient: reshape the SATA data partition
# from "HA owns the whole thing at /var/lib/home-assistant" into the general
# /srv layout the new configuration.nix expects, and move Frigate recordings
# onto a fixed-size 40G loopback filesystem.
#
#   Old:  /var/lib/home-assistant/            (partition root = HA /config)
#           frigate/{config,media}            (media = 71G of loose recordings)
#           bento/  shenas/
#   New:  /srv/                               (partition root, root-owned)
#           home-assistant/                   (HA /config)
#           frigate/config
#           frigate/media.img                 (40G ext4 image)
#           frigate/media                     (mountpoint for the image)
#           bento/  shenas/  containers/      (containers = podman graphroot)
#
# RUN THIS ON THE BOX (over SSH), as the OLD config is still active and the
# partition is still mounted at /var/lib/home-assistant. After it finishes,
# push the repo and `make switch-ha`, then reboot the box (see the tail of this
# script). It is safe to re-run: every step checks whether it has already
# happened.
#
# Requires sudo/root. Idempotent. Nothing here is destructive beyond trimming
# the OLDEST Frigate recordings down to fit the 40G cap (that footage is
# discarded by design — the newest ~KEEP_GB are preserved).

set -euo pipefail

OLD=/var/lib/home-assistant          # current mountpoint (pre-switch)
KEEP_GB=34                           # trim recordings down to this before imaging
                                     # (leaves headroom for the 40G image on the
                                     #  78G partition alongside HA/bento state)
IMG="$OLD/frigate/media.img"
MEDIA="$OLD/frigate/media"

if [ "$(id -u)" -ne 0 ]; then
  echo "run as root (sudo $0)" >&2
  exit 1
fi

if ! mountpoint -q "$OLD"; then
  echo "ERROR: $OLD is not a mounted partition — are you on the box, pre-switch?" >&2
  exit 1
fi

echo "==> 1/6  Stopping containers (release the partition, stop recording writes)"
systemctl stop podman-frigate podman-homeassistant podman-bento podman-shenas-kiosk || true

echo "==> 2/6  Trimming oldest Frigate recordings to <= ${KEEP_GB}G"
# Frigate 0.17 layout: recordings/YYYY-MM-DD/HH/<camera>/MM.SS.mp4
# Delete whole oldest day-directories (lexically smallest = oldest) until the
# media tree is under the target. Byte-exact (du -sb) so there's no rounding,
# and every iteration REVALIDATES the size — if we can't measure it, we STOP
# rather than keep deleting (the previous du -BG/awk version could fail to
# parse, never satisfy the <= check, and delete *everything*; that bug wiped
# the recordings on the first real run).
keep_bytes=$(( KEEP_GB * 1024 * 1024 * 1024 ))
if [ -d "$MEDIA/recordings" ]; then
  while :; do
    used=$(du -sb "$MEDIA" 2>/dev/null | cut -f1)
    case "$used" in
      ''|*[!0-9]*) echo "    WARNING: cannot measure $MEDIA (got '$used'); stopping trim"; break ;;
    esac
    [ "$used" -le "$keep_bytes" ] && { echo "    $((used/1024/1024/1024))G <= ${KEEP_GB}G; done"; break; }
    oldest=$(find "$MEDIA/recordings" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort | head -1)
    if [ -z "$oldest" ]; then
      echo "    no more recordings day-dirs to trim (still $((used/1024/1024/1024))G); stopping"
      break
    fi
    echo "    $((used/1024/1024/1024))G used — deleting oldest: $oldest"
    rm -rf "$oldest"
  done
else
  echo "    no recordings/ dir found; skipping trim"
fi

echo "==> 3/6  Creating the 40G ext4 loopback image (if absent)"
if [ ! -e "$IMG" ]; then
  truncate -s 40G "$IMG"
  mkfs.ext4 -F -L frigate-media "$IMG"
else
  echo "    $IMG already exists; leaving it"
fi

echo "==> 4/6  Moving surviving recordings into the image"
MNT=$(mktemp -d)
mount -o loop "$IMG" "$MNT"
# Copy only if the image is still empty (idempotency: a re-run won't duplicate).
if [ -z "$(ls -A "$MNT")" ] && [ -d "$MEDIA" ] && [ -n "$(ls -A "$MEDIA" 2>/dev/null)" ]; then
  cp -a "$MEDIA/." "$MNT/"
fi
umount "$MNT"; rmdir "$MNT"
# Empty the loose media dir so it becomes a clean mountpoint (contents now live
# inside the image, which the new config mounts here after the switch).
rm -rf "$MEDIA"
mkdir -p "$MEDIA"

echo "==> 5/6  Moving HA state into the home-assistant/ subdir"
mkdir -p "$OLD/home-assistant"
shopt -s dotglob nullglob
for e in "$OLD"/*; do
  b=$(basename "$e")
  case "$b" in
    home-assistant|frigate|bento|shenas|containers|lost+found) continue ;;
  esac
  echo "    mv $b -> home-assistant/"
  mv "$e" "$OLD/home-assistant/"
done
shopt -u dotglob nullglob

echo "==> 6/6  Normalizing partition-root ownership (HA no longer owns it)"
chown root:root "$OLD"
chmod 0755 "$OLD"
mkdir -p "$OLD/containers"

cat <<EOF

Migration complete. The partition now holds the /srv layout (still visible at
$OLD until you switch). Next, from your workstation:

  git add -A && git commit && git push
  make switch-ha
  ssh ha sudo reboot          # cleanly remount the partition at /srv

After the box is back up and healthy, reclaim the old podman store on the eMMC:

  ssh ha 'sudo rm -rf /var/lib/containers/storage'

Verify:
  ssh ha 'df -h / /srv /srv/frigate/media; findmnt /srv/frigate/media'
EOF
