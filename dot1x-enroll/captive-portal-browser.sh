#!/usr/bin/env bash
# Opens Google Chrome on the captive portal for the desktop user, in place of GNOME's portal helper, which Ubuntu no longer ships.
# Runs as the desktop user: started by dot1x-enroll once the port is authorized, and by the NetworkManager dispatcher and autostart.

# Any plain HTTP URL works: PacketFence redirects it to the portal
PORTAL_PROBE_URL="http://connectivity-check.ubuntu.com/"
# A separate profile, so the portal window never mixes with the user's own browsing
PROFILE_DIR="$XDG_RUNTIME_DIR/captive-portal-profile"

# Before 802.1X PacketFence serves the MAB profile's login page; dot1x-enroll opens the portal once the port is authorized
[ -f /run/dot1x-enroll-authorized ] || exit 0
[ "$(nmcli -t -f CONNECTIVITY general)" = portal ] || exit 0

mkdir -p "$PROFILE_DIR"

# Kiosk: full screen with no tabs, address bar or menus, so the window is only the portal; it closes once the network is open.
# The basic password store avoids a keyring unlock prompt, since the auto-login session has no keyring password.
exec google-chrome-stable --kiosk --no-first-run --no-default-browser-check --password-store=basic \
  --user-data-dir="$PROFILE_DIR" "$PORTAL_PROBE_URL"
