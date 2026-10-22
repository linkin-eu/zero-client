# The captive portal window, opened only by dot1x-enroll so that two callers never race to start it.

# Starts the portal window unless it is already open; the browser script itself exits when there is no portal,
# and before the desktop session exists the start fails quietly and the next check retries it
open_portal_browser() {
  systemctl --user --machine="$DESKTOP_USER@" is-active --quiet captive-portal-browser && return 0
  systemd-run --user --machine="$DESKTOP_USER@" --unit=captive-portal-browser --collect \
    /usr/local/bin/captive-portal-browser.sh >/dev/null 2>&1 || true
}

close_portal_browser() {
  systemctl --user --machine="$DESKTOP_USER@" stop captive-portal-browser >/dev/null 2>&1 || true
}
