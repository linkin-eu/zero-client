#!/usr/bin/env bash
set -euox pipefail

# Package prompts (console-setup, keyboard) would stop the unattended build; take their defaults
export DEBIAN_FRONTEND=noninteractive

# APT SOURCES: debootstrap only adds the release pocket, so without updates and security every package stays at release day
cat >/etc/apt/sources.list <<EOF
deb http://archive.ubuntu.com/ubuntu noble main universe
deb http://archive.ubuntu.com/ubuntu noble-updates main universe
deb http://security.ubuntu.com/ubuntu noble-security main universe
EOF
apt update
apt upgrade -y

# INSTALL PACKAGES
apt install -y linux-image-generic software-properties-common
add-apt-repository -y universe
apt install -y systemd-boot ansible

# VALIDATE ESP
if ! mountpoint -q /boot/efi; then
  echo "ERROR: ESP is not mounted at /boot/efi" >&2
  exit 1
fi

# REBUILD INITRAMFS (once)
echo "==> Rebuilding initramfs..."
update-initramfs -u -k all

# GET ROOT PARTITION PARTUUID
ROOT_PARTUUID=$(blkid -s PARTUUID -o value "$(findmnt -n -o SOURCE /)")
echo "==> Root partition PARTUUID: $ROOT_PARTUUID"

# INSTALL SYSTEMD-BOOT
echo "==> Installing systemd-boot to ESP..."
bootctl install --esp-path=/boot/efi --no-variables

# CONFIGURE LOADER
cat >/boot/efi/loader/loader.conf <<EOF
default ubuntu.conf
timeout 3
console-mode max
editor no
EOF

# GET KERNEL VERSION
KERNEL_VERSION=$(ls /boot/vmlinuz-* | sed 's/.*vmlinuz-//' | head -n1)

# CREATE BOOT ENTRY WITH PARTUUID
cat >"/boot/efi/loader/entries/ubuntu.conf" <<EOF
title   Ubuntu Zero Client
linux   /vmlinuz-${KERNEL_VERSION}
initrd  /initrd.img-${KERNEL_VERSION}
options root=PARTUUID=${ROOT_PARTUUID} ro quiet splash
EOF

# COPY KERNEL AND INITRD TO ESP
echo "==> Copying kernel and initramfs to ESP..."
cp "/boot/vmlinuz-${KERNEL_VERSION}" /boot/efi/
cp "/boot/initrd.img-${KERNEL_VERSION}" /boot/efi/
# Note: FAT32 doesn't support symlinks, so we skip creating vmlinuz/initrd.img symlinks

# VALIDATE
echo "==> Validating systemd-boot installation..."
test -f /boot/efi/EFI/BOOT/BOOTX64.EFI || echo "WARNING: BOOTX64.EFI not found"
test -f /boot/efi/loader/loader.conf || echo "WARNING: loader.conf not found"

echo "==> systemd-boot configuration:"
cat /boot/efi/loader/loader.conf
echo ""
echo "==> Boot entry:"
cat /boot/efi/loader/entries/ubuntu.conf

# ENABLE SERVICES
systemctl enable ansible-first-boot.service || true

# 802.1X ENROLLMENT (only in images built for a plant)
if [ -f /etc/dot1x-enroll.conf ]; then
  apt install -y wpasupplicant openssl wget network-manager network-manager-config-connectivity-ubuntu
  systemctl enable dot1x-enroll.service
  # NetworkManager owns Ethernet (90-networkmanager.yaml); networkd would wait for links it no longer manages
  systemctl disable systemd-networkd-wait-online.service || true
  systemctl enable NetworkManager.service NetworkManager-wait-online.service
fi

# SET TIMEZONE
ln -sf /usr/share/zoneinfo/Europe/Sofia /etc/localtime
echo "Europe/Sofia" > /etc/timezone

# SET HOSTNAME: debootstrap copies the build host's name; Ansible sets the same name at runtime
echo "LINKIN-ZERO-4" > /etc/hostname
echo "127.0.1.1 LINKIN-ZERO-4" >> /etc/hosts

# CREATE DEFAULT USER
useradd -m -c "Linkin Zero Client" -d /home/zero -s /bin/bash zero

# RUN ANSIBLE
if [ -f /root/zero.yml ]; then
  LC_ALL=C.UTF-8 LANG=C.UTF-8 ZEROSTATE=CHROOT ansible-playbook /root/zero.yml -v
else
  echo "WARNING: /root/zero.yml not found, skipping ansible-playbook" >&2
fi