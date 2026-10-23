#!/usr/bin/env bash
# Reboots after the first Ansible run. On 802.1X images that run starts only once the network is open, which can be
# after the user has signed in at the portal and started working, so a desktop session gets a warning and some minutes
# to save its work instead of an instant reboot.

DESKTOP_USER=zero
REBOOT_DELAY_MINUTES=10

if [ "$(loginctl show-user "$DESKTOP_USER" -p State --value 2>/dev/null)" != active ]; then
  exec systemctl reboot
fi

# GNOME Shell serves the notification interface under its own name; critical urgency keeps it on screen until dismissed
timeout 10 systemd-run --user --machine="$DESKTOP_USER@" --collect --quiet \
  gdbus call --session --dest org.gnome.Shell --object-path /org/freedesktop/Notifications \
  --method org.freedesktop.Notifications.Notify "Zero Client" 0 system-reboot \
  "Restart in $REBOOT_DELAY_MINUTES minutes" \
  "Setup has finished. Save your work: the computer restarts in $REBOOT_DELAY_MINUTES minutes." \
  "[]" "{'urgency': <byte 2>}" 0
exec shutdown -r "+$REBOOT_DELAY_MINUTES"
