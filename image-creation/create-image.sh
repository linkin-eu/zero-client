#!/usr/bin/env bash
set -euo pipefail
set -x

SCRIPT_DIR="$(dirname "$(realpath "$0")")"
ANSIBLE_DIR="$SCRIPT_DIR/../ansible"
SERVICES_DIR="$SCRIPT_DIR/../services"
DOT1X_ENROLL_DIR="$SCRIPT_DIR/../dot1x-enroll"
ROOT_MOUNT_PATH="/mnt/zero-img"
IMAGE="zero-client.img"
# Optional: with a plant the image enrolls a certificate over SCEP and authenticates the wired port with 802.1X
PLANT="${1:-}"
# The branch the device pulls ansible/zero.yml from after the first boot; test images can follow a feature branch
PLAYBOOK_BRANCH="${PLAYBOOK_BRANCH:-v4}"

cleanup() {
  # No tracing here: the loop below visits every process on the host
  set +ex
  sync

  # Daemons started inside the chroot (gpg-agent, dirmngr) keep the image busy, so they are stopped first;
  # only processes whose root is the image are touched
  for process_root in /proc/[0-9]*/root; do
    if [ "$(readlink "$process_root" 2>/dev/null)" = "$ROOT_MOUNT_PATH" ]; then
      kill "$(basename "$(dirname "$process_root")")" 2>/dev/null
    fi
  done
  sleep 1

  umount -R "$ROOT_MOUNT_PATH" 2>/dev/null || umount -R -l "$ROOT_MOUNT_PATH" 2>/dev/null || true

  # After a lazy unmount the loop device stays busy for a moment
  if [ -n "${LOOP_DEVICE:-}" ]; then
    for attempt in 1 2 3 4 5 6 7 8 9 10; do
      losetup -d "$LOOP_DEVICE" 2>/dev/null && break
      sleep 1
    done
  fi

  if [ -n "${DOT1X_SECRETS_DIR:-}" ]; then
    rm -rf "$DOT1X_SECRETS_DIR"
  fi
}
trap cleanup EXIT INT TERM

if [ -n "$PLANT" ]; then
  DOT1X_SECRETS_DIR="$(mktemp -d)"
  "$SCRIPT_DIR/prepare-dot1x-enroll.sh" "$PLANT" "$DOT1X_SECRETS_DIR"
fi

# Create image
dd if=/dev/zero of="$IMAGE" bs=1G count=10

# Attach loop device with partition scanning
LOOP_DEVICE="$(losetup -fP --show "$IMAGE")"

# Partition the loop device (GPT: 500M ESP + rest Linux)
{
  echo 'label: gpt'
  echo 'size=500M, type=U'
  echo ',,L'
} | sfdisk "$LOOP_DEVICE"

# Tell kernel to re-scan partitions
partx -u "$LOOP_DEVICE" 2>/dev/null || true
sleep 1

ESP_PART="${LOOP_DEVICE}p1"
ROOT_PART="${LOOP_DEVICE}p2"

# Wait for partition devices to appear
for i in {1..20}; do
  [ -b "$ESP_PART" ] && [ -b "$ROOT_PART" ] && break
  echo "Waiting for partitions to appear... ($i/20)"
  sleep 0.5
done

if [ ! -b "$ESP_PART" ] || [ ! -b "$ROOT_PART" ]; then
  echo "ERROR: Partitions not found after sfdisk!" >&2
  lsblk "$LOOP_DEVICE" || true
  exit 1
fi

lsblk "$LOOP_DEVICE"

# Format ESP
mkfs.vfat -F32 -n ZEROEFI "$ESP_PART"

# Format root (USB-friendly: fully initialize now; no reserved blocks)
mkfs.ext4 -L ZEROROOT -m 0 -E lazy_itable_init=0,lazy_journal_init=0 "$ROOT_PART"

# Set journal writeback mode (less writes, better for USB)
tune2fs -o journal_data_writeback "$ROOT_PART"

# Mount root + esp
mkdir -p "$ROOT_MOUNT_PATH"
mount "$ROOT_PART" "$ROOT_MOUNT_PATH"
mkdir -p "$ROOT_MOUNT_PATH/boot/efi"
mount "$ESP_PART" "$ROOT_MOUNT_PATH/boot/efi"

# Bootstrap
debootstrap --arch=amd64 noble "$ROOT_MOUNT_PATH" http://archive.ubuntu.com/ubuntu/

# Prepare chroot mounts
mkdir -p "$ROOT_MOUNT_PATH"/{proc,sys,dev,run,dev/pts}
mount -t proc /proc "$ROOT_MOUNT_PATH/proc"
mount --rbind /sys "$ROOT_MOUNT_PATH/sys"
mount --rbind /dev "$ROOT_MOUNT_PATH/dev"
mount --bind /run "$ROOT_MOUNT_PATH/run"
mount --bind /dev/pts "$ROOT_MOUNT_PATH/dev/pts"
# One-way propagation: the bind mounts follow the host, but unmounting them never unmounts the host's /sys or /dev
mount --make-rslave "$ROOT_MOUNT_PATH"

# Services and playbook
cp "$SERVICES_DIR/"*.service "$ROOT_MOUNT_PATH/etc/systemd/system/" 2>/dev/null || true
cp "$SERVICES_DIR/"*.timer   "$ROOT_MOUNT_PATH/etc/systemd/system/" 2>/dev/null || true
cp "$ANSIBLE_DIR/zero.yml" "$ROOT_MOUNT_PATH/root/zero.yml"
echo "PLAYBOOK_BRANCH=$PLAYBOOK_BRANCH" > "$ROOT_MOUNT_PATH/etc/default/zero-client"

# 802.1X enrollment; modify-chroot.sh installs its packages and enables it when /etc/dot1x-enroll.conf exists
if [ -n "$PLANT" ]; then
  install -m 0600 "$DOT1X_SECRETS_DIR/dot1x-enroll.conf" "$ROOT_MOUNT_PATH/etc/dot1x-enroll.conf"
  install -m 0755 "$DOT1X_SECRETS_DIR/scepclient" "$ROOT_MOUNT_PATH/usr/local/bin/scepclient"
  install -m 0755 "$DOT1X_ENROLL_DIR/dot1x-enroll.sh" "$DOT1X_ENROLL_DIR/dot1x-enroll-monitor.sh" "$ROOT_MOUNT_PATH/usr/local/bin/"
  install -m 0644 "$DOT1X_ENROLL_DIR/dot1x-enroll.service" "$DOT1X_ENROLL_DIR/dot1x-supplicant@.service" "$ROOT_MOUNT_PATH/etc/systemd/system/"
  install -D -m 0600 "$DOT1X_ENROLL_DIR/90-networkmanager.yaml" "$ROOT_MOUNT_PATH/etc/netplan/90-networkmanager.yaml"
  # An empty file here overrides the packaged one that leaves Ethernet unmanaged outside Ubuntu Desktop
  install -D -m 0644 /dev/null "$ROOT_MOUNT_PATH/etc/NetworkManager/conf.d/10-globally-managed-devices.conf"
  install -D -m 0644 "$DOT1X_ENROLL_DIR/90-connectivity-interval.conf" "$ROOT_MOUNT_PATH/etc/NetworkManager/conf.d/90-connectivity-interval.conf"
  # Google Chrome on the captive portal instead of GNOME's portal helper
  install -m 0755 "$DOT1X_ENROLL_DIR/captive-portal-browser.sh" "$ROOT_MOUNT_PATH/usr/local/bin/"
  install -D -m 0755 "$DOT1X_ENROLL_DIR/90-captive-portal" "$ROOT_MOUNT_PATH/etc/NetworkManager/dispatcher.d/90-captive-portal"
  install -D -m 0644 "$DOT1X_ENROLL_DIR/captive-portal-browser.desktop" "$ROOT_MOUNT_PATH/etc/xdg/autostart/captive-portal-browser.desktop"
  # No reporting, sign-in, prompts or DNS-over-HTTPS: on the registration VLAN they only add requests to the portal
  install -D -m 0644 "$DOT1X_ENROLL_DIR/chrome-policies.json" "$ROOT_MOUNT_PATH/etc/opt/chrome/policies/managed/zero-client.json"
fi

# fstab (USB read-mostly)
cat >"$ROOT_MOUNT_PATH/etc/fstab" <<'EOF'
LABEL=ZEROROOT / ext4 defaults,noatime,nodiratime,commit=60,errors=remount-ro 0 1
LABEL=ZEROEFI /boot/efi vfat defaults,noatime 0 0
tmpfs /tmp      tmpfs defaults,noatime,mode=1777 0 0
tmpfs /var/tmp  tmpfs defaults,noatime,mode=1777 0 0
tmpfs /var/log  tmpfs defaults,noatime,mode=0755 0 0
tmpfs /var/cache tmpfs defaults,noatime,mode=0755 0 0
EOF

# Chroot
cp "$SCRIPT_DIR/modify-chroot.sh" "$ROOT_MOUNT_PATH/root/modify-chroot.sh"
chmod +x "$ROOT_MOUNT_PATH/root/modify-chroot.sh"

chroot "$ROOT_MOUNT_PATH" /usr/bin/env -i \
  HOME=/root TERM="$TERM" \
  PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
  /root/modify-chroot.sh

rm -f "$ROOT_MOUNT_PATH/root/modify-chroot.sh"
