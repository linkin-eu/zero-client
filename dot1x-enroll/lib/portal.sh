# The captive portal window. Only dot1x-enroll opens it, from decision_window; the NetworkManager dispatcher
# only closes it once the network is open.

portal_window_open() {
  bounded 10 systemctl --user --machine="$DESKTOP_USER@" is-active --quiet captive-portal-browser
}

# Before the desktop session exists the start fails quietly and the next check tries again
open_portal_window() {
  portal_window_open && return 0
  bounded 15 systemd-run --user --machine="$DESKTOP_USER@" --unit=captive-portal-browser --collect \
    /usr/local/bin/captive-portal-browser.sh >/dev/null 2>&1 || true
}

close_portal_window() {
  portal_window_open || return 0
  bounded 15 systemctl --user --machine="$DESKTOP_USER@" stop captive-portal-browser >/dev/null 2>&1 || true
}

apply_window_decision() {
  case "$1" in
    closed) close_portal_window ;;
    open) open_portal_window ;;
    fresh)
      close_portal_window
      open_portal_window
      ;;
  esac
}
