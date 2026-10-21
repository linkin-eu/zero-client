#!/usr/bin/env bash
set -euox pipefail

apt update
apt install -y debootstrap squashfs-tools mtools grub-efi-amd64-bin dosfstools unzip
# 802.1X enrollment reads its SCEP settings from SSM at build time
snap install aws-cli --classic
