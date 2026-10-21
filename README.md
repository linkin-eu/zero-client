# Zero Client

A bootable Ubuntu 24.04 LTS system optimized for thin client workloads, featuring automatic remote management and USB flash drive longevity optimizations.

## Overview

Zero Client creates a fully automated, bootable USB image that provides a minimal Ubuntu desktop environment with pre-installed remote desktop clients (AWS WorkSpaces, Parsec). The system features automatic updates via Ansible and is optimized for USB flash drive deployment with read-mostly filesystem strategies.

## Features

- **Ubuntu 24.04 Noble LTS** - Latest long-term support release
- **systemd-boot** - Modern, simple UEFI bootloader (no legacy BIOS support)
- **USB Longevity Optimizations**:
  - `journal_data_writeback` mode for minimal writes
  - `noatime` and `nodiratime` mount options
  - Extended commit intervals (60 seconds)
  - tmpfs for frequently written directories (`/tmp`, `/var/log`, `/var/cache`, `/var/tmp`)
  - No reserved blocks, fully initialized filesystem
- **Remote Management**:
  - Ansible-based configuration
  - Automatic updates from GitHub on boot
  - Hourly update checks via systemd timer
  - Remote configuration changes via repository updates
- **Pre-installed Applications**:
  - AWS WorkSpaces Client (from official repository)
  - Parsec Client
  - GNOME minimal desktop environment
  - Firefox, GNOME Terminal, System Monitor
- **Localization**:
  - Bulgarian (bg_BG) and English (en_US) keyboard layouts
  - Alt+Shift keyboard switching
  - Automatic timezone detection via IP geolocation
- **Auto-login** - Passwordless login to `zero` user with unlock capability
- **Network Optimizations** - DSCP marking for QoS (CS5 for remote desktop traffic)

## Requirements

### Build System
- Ubuntu 24.04 (or compatible)
- `sudo` access (for loop device and chroot operations)
- Required packages (install automatically):
  ```bash
  cd image-creation
  sudo ./requirements.sh
  ```
  Or manually:
  ```bash
  sudo apt install debootstrap ansible wget pv
  ```

### Target Hardware
- UEFI-capable system (BIOS/Legacy boot not supported)
- Minimum 16GB USB flash drive
- Network connectivity (DHCP)

## Quick Start

### 1. Create the Image

```bash
cd image-creation
sudo ./create-image.sh
```

This will:
- Create a 10GB bootable image (`zero-client.img`)
- Set up GPT partitioning (500MB ESP + root)
- Install Ubuntu 24.04 base system
- Configure systemd-boot
- Run Ansible playbook for system configuration
- Takes ~20-30 minutes depending on internet speed

To build an image that authenticates the wired port with 802.1X (see [802.1X EAP-TLS Enrollment](#8021x-eap-tls-enrollment)), pass the plant:

```bash
sudo ./create-image.sh 2001
```

After the first boot the device pulls `ansible/zero.yml` from the `v4` branch. A test image can follow another branch, kept in `/etc/default/zero-client` on the device:

```bash
sudo PLAYBOOK_BRANCH=feature/my-change ./create-image.sh 2001
```

### 2. Burn to USB Drive

**Single USB:**
```bash
sudo ./burn-to-usb.sh
```

**Multiple USBs in parallel:**
```bash
sudo ./burn-to-multi-usb.sh
```

The multi-USB script will:
- Auto-detect all removable USB drives
- Burn images in parallel with progress indicators
- Save logs for each drive

### 3. Boot from USB

1. Insert USB drive into target system
2. Boot from USB (F12/F11/DEL to access boot menu)
3. System will auto-login and complete first-boot setup
4. Automatic reboot after first-boot configuration
5. Ready to use!

## Architecture

### Directory Structure

```
zero-client/
├── ansible/
│   └── zero.yml              # Main Ansible playbook
├── desktop/
│   ├── wallpaper.jpg         # Desktop wallpaper
│   └── gsettings.sh          # GNOME settings script
├── image-creation/
│   ├── create-image.sh       # Main image creation script
│   ├── modify-chroot.sh      # Chroot configuration script
│   ├── prepare-dot1x-enroll.sh # Fetch 802.1X enrollment settings from SSM
│   ├── requirements.sh       # Install build dependencies
│   ├── burn-to-usb.sh        # Single USB burning
│   └── burn-to-multi-usb.sh  # Parallel multi-USB burning
└── services/
    ├── ansible-first-boot.service  # First boot Ansible run
    ├── ansible-boot.service        # Every boot Ansible run
    ├── ansible-cron.service        # Hourly Ansible run
    └── ansible-cron.timer          # Timer for periodic updates
└── dot1x-enroll/                   # SCEP enrollment and wired 802.1X EAP-TLS (installed with a plant)
```

### Boot Process

1. **UEFI Firmware** → systemd-boot
2. **systemd-boot** → Linux kernel (from ESP)
3. **Kernel** → initramfs → root filesystem (PARTUUID)
4. **systemd** → GDM3 → auto-login user `zero`
5. **First Boot** → `ansible-first-boot.service`:
   - Downloads latest `zero.yml` from GitHub (v4 branch)
   - Runs Ansible playbook
   - Enables boot and cron services
   - Reboots
6. **Subsequent Boots** → `ansible-boot.service`:
   - Downloads latest config on every boot
   - Applies updates
7. **Hourly** → `ansible-cron.timer` + `ansible-cron.service`:
   - Checks for updates every hour
   - Random delay up to 10 minutes

### Filesystem Layout

```
Partition Table: GPT
├── /dev/sdX1 (500M) - LABEL=ZEROEFI
│   └── FAT32, ESP, systemd-boot files, kernel, initramfs
└── /dev/sdX2 (~9.5G) - LABEL=ZEROROOT
    └── ext4, root filesystem

Mount Points:
/                   - LABEL=ZEROROOT (ext4, noatime, nodiratime, commit=60)
/boot/efi           - LABEL=ZEROEFI (vfat, noatime)
/tmp                - tmpfs (RAM)
/var/tmp            - tmpfs (RAM)
/var/log            - tmpfs (RAM)
/var/cache          - tmpfs (RAM)
```

## Remote Management

The system automatically pulls configuration from GitHub on every boot and hourly. To update deployed systems:

1. Edit `ansible/zero.yml` in the repository
2. Commit and push to the `v4` branch
3. Devices will auto-update within 1 hour (or on next boot)

### Configuration URLs

Services download from:
```
https://raw.githubusercontent.com/techno-link/zero-client/v4/ansible/zero.yml
```

Desktop files from:
```
https://raw.githubusercontent.com/techno-link/zero-client/v4/desktop/wallpaper.jpg
https://raw.githubusercontent.com/techno-link/zero-client/v4/desktop/gsettings.sh
```

### Logs

Ansible execution logs:
- `/home/zero/.config/linkin/ansible-first-boot.log`
- `/home/zero/.config/linkin/ansible-boot.log`
- `/home/zero/.config/linkin/ansible-cron.log`

## 802.1X EAP-TLS Enrollment

Images built with a plant (`sudo ./create-image.sh <plant>`) authenticate the wired port with a certificate, like the Yocto RPi devices do on Wi-Fi:

1. Boot on the PacketFence onboarding VLAN (MAC authentication fallback on the switch port)
2. Request a certificate over SCEP from PacketFence (CN `zero-<plant>-<ethernet mac>`, CA pinned by fingerprint)
3. Start 802.1X EAP-TLS on the port and renew DHCP; fall back to the onboarding VLAN when it is not authorized, re-enroll when the certificate is invalid, refused or revoked (OCSP)

Build-time settings come from the Yocto RPi SSM parameter `/yocto/<plant>/scep` (`eu-central-1`), read with the AWS credentials of the user running `sudo`.
It must hold `KEY="value"` lines for `SCEP_HOST`, `SCEP_CHALLENGE`, `CA_FINGERPRINT`, `RADIUS_DOMAIN`, `OCSP_HOST`.
The PacketFence PKI template is not taken from SSM: thin clients use their own, set by `SCEP_TEMPLATE` in `image-creation/prepare-dot1x-enroll.sh`.

On the device:
- Settings: `/etc/dot1x-enroll.conf` (root only); certificate, key and EAP config: `/var/lib/dot1x-enroll/`
- Logs: `journalctl -u dot1x-enroll -u 'dot1x-supplicant@*'`
- Reset: `sudo rm -rf /var/lib/dot1x-enroll && sudo reboot`

The SCEP challenge is shared by all devices of a plant and the disk is not encrypted, so anyone holding a USB stick can enroll a certificate; restrict the thin client PacketFence role accordingly.

## USB Optimization Details

### Filesystem Options

**ext4 (root):**
- `noatime` - Don't update file access times
- `nodiratime` - Don't update directory access times
- `commit=60` - Sync metadata every 60 seconds (vs 5 default)
- `data=writeback` - Journal metadata only, not data
- `errors=remount-ro` - Remount read-only on errors

**Format options:**
- `-m 0` - No reserved blocks (USB doesn't need root-only space)
- `-E lazy_itable_init=0,lazy_journal_init=0` - Full initialization at creation

### Write Reduction Strategy

| Directory | Strategy | Reason |
|-----------|----------|--------|
| `/tmp` | tmpfs (RAM) | Temporary files don't need persistence |
| `/var/tmp` | tmpfs (RAM) | Application temp files |
| `/var/log` | tmpfs (RAM) | Logs not needed after reboot |
| `/var/cache` | tmpfs (RAM) | APT cache, rebuild on boot |

**Trade-off:** Logs are lost on power loss, but USB lifespan dramatically increased.

## Security Considerations

- **Auto-login enabled** for user `zero` (thin client use case)
- **Screen lock disabled** (can be re-enabled in Ansible playbook)
- **No password required** for unlock (nopasswdlogin group)
- **DHCP networking** - No static IP configuration
- **Automatic updates** - Security patches applied automatically

⚠️ **Note:** This system is designed for trusted network environments (corporate LANs, etc.). Not recommended for public/untrusted networks.

## Troubleshooting

### Image Creation Fails

**Partition devices not found:**
```bash
# Ensure loop device module is loaded
sudo modprobe loop

# Check available loop devices
sudo losetup -a
```

**Out of disk space:**
- Image creation requires ~15GB free space
- Check with `df -h`

### Boot Issues

**System doesn't boot (UEFI):**
- Verify UEFI boot is enabled in BIOS
- Legacy/CSM mode must be disabled
- Secure Boot may need to be disabled

**Kernel panic / can't find root:**
- PARTUUID may have changed
- Boot into rescue mode and check `/boot/efi/loader/entries/ubuntu.conf`

### Ansible Fails

**Network not available:**
- Check `systemctl status ansible-boot.service`
- Service waits for `network-online.target`
- Verify DHCP is working

**Tasks fail in chroot:**
- Some tasks skip in chroot with `ZEROSTATE=CHROOT` check
- This is expected (e.g., hostname, snapd, reboot)

### USB Write Issues

**Permission denied:**
```bash
# Must run with sudo
sudo ./burn-to-usb.sh
```

**Device busy:**
```bash
# Unmount all partitions first
sudo umount /dev/sdX*
```

## Development

### Branch Strategy

- `master` - Stable releases
- `v4` - Current development (Ubuntu 24.04)
- `v3` - Previous version (Ubuntu 22.04, deprecated)
- `feat/*` - Feature branches

### Modifying the Playbook

1. Edit `ansible/zero.yml`
2. Test locally:
   ```bash
   sudo ansible-playbook ansible/zero.yml -v
   ```
3. Commit and push to `v4` branch
4. Deployed systems will auto-update

### Creating a New Version

```bash
# Create new branch
git checkout -b v5

# Update branch_version in zero.yml
# Update URLs in services/*

# Commit and push
git add -A
git commit -m "feat: Version 5 with new features"
git push -u origin v5
```

## Technical Specifications

| Component | Version/Config |
|-----------|----------------|
| **OS** | Ubuntu 24.04 LTS (Noble Numbat) |
| **Kernel** | linux-image-generic (latest) |
| **Bootloader** | systemd-boot 255+ |
| **Desktop** | GNOME (minimal) with GDM3 |
| **Display Server** | Wayland |
| **Filesystem** | ext4 (root), FAT32 (ESP) |
| **Partition Scheme** | GPT |
| **Image Size** | 10GB |
| **Minimum USB** | 16GB |

## Contributing

1. Fork the repository
2. Create a feature branch (`git checkout -b feat/new-feature`)
3. Test changes thoroughly
4. Commit with clear messages
5. Push and create a Pull Request

## License

This project is for internal use. See repository settings for license details.

## Acknowledgments

- Built with [Ansible](https://www.ansible.com/)
- Ubuntu 24.04 LTS by [Canonical](https://ubuntu.com/)
- systemd-boot from [systemd project](https://www.freedesktop.org/wiki/Software/systemd/)

---

**Version:** v4
**Last Updated:** 2024-12-20
**Maintainer:** techno-link