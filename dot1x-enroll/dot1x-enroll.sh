#!/usr/bin/env bash
# Moves the wired port from the PacketFence onboarding VLAN (MAC authentication) to 802.1X EAP-TLS. The
# certificate is requested over SCEP and kept in /var/lib/dot1x-enroll; when EAP-TLS stops working the EAP
# config is moved aside and the next run enrolls again if the certificate is no longer valid, was refused,
# or is revoked. dot1x-enroll-monitor.sh runs it again, sooner after a failed run (non-zero exit) or at once
# when a captive portal is detected, so the device recovers on its own. The helpers live in lib/.

source /etc/dot1x-enroll.conf

# PacketFence serves SCEP per template over HTTP; the CA is pinned by CA_FINGERPRINT
SCEP_URL="http://$SCEP_HOST/scep/$SCEP_TEMPLATE"
# The OCSP responder answers on both VLANs, unlike the SCEP host
OCSP_URL="https://$OCSP_HOST/pki/ocsp"

DOT1X_DIR=/var/lib/dot1x-enroll
EAP_CONFIG=$DOT1X_DIR/wpa_supplicant.conf
CONNECT_TIMEOUT=60
# How long a link bounce may take to come back before the address is renewed
CARRIER_TIMEOUT=10
# After EAP-TLS refused us with the cable plugged in, the next switch waits this long, so a lasting
# RADIUS outage does not drop the onboarding connection on every run. A refusal while OCSP still reports
# the certificate as good is a policy decision, so the same certificate is retried: only an invalid,
# expired or revoked certificate is replaced (the revocation check runs on every pass).
SWITCH_RETRY_AFTER=60
SWITCH_REFUSED=$DOT1X_DIR/switch-refused

# Read by captive-portal-browser.sh: before 802.1X PacketFence serves the MAB connection profile, whose login page differs
AUTHORIZED_MARKER=/run/dot1x-enroll-authorized
DESKTOP_USER=zero

# A stale address is renewed at most this often
RENEW_STALE_AFTER=30
STALE_RENEWED=/run/dot1x-enroll-stale-renewed

INTERFACE=$(basename "$(ls -d /sys/class/net/en* 2>/dev/null | head -n1)")
WPA_SERVICE=dot1x-supplicant@$INTERFACE
# One identity per device for the certificate and PacketFence; the hostname is shared by all thin clients
COMMON_NAME="zero-$PLANT-$(tr -d : < "/sys/class/net/$INTERFACE/address" 2>/dev/null)"

LIB_DIR=/usr/local/lib/dot1x-enroll
source "$LIB_DIR/log.sh"
source "$LIB_DIR/cert.sh"
source "$LIB_DIR/port.sh"
source "$LIB_DIR/portal.sh"
trap flush_log EXIT
# A service stop or restart ends the run through EXIT, so its buffered messages still reach the journal
trap 'exit 1' TERM INT

# The captive portal is opened only from here, once the port runs 802.1X and PacketFence serves the right login page
on_authorized() {
  log "Authorized on $INTERFACE"
  rm -f "$SWITCH_REFUSED"
  renew_address
  touch "$AUTHORIZED_MARKER"
  nmcli networking connectivity check >/dev/null 2>&1
  # A fresh window, so the page comes from the VLAN the port is on now
  close_portal_browser
  open_portal_browser
}

if [ -z "$INTERFACE" ]; then
  log "FAIL: no Ethernet interface"
  exit 1
fi

mkdir -p "$DOT1X_DIR"
chmod 700 "$DOT1X_DIR"

# A revoked certificate is replaced from the onboarding VLAN, the only one that reaches SCEP
if [ -f "$DOT1X_DIR/device.crt" ] && certificate_revoked; then
  log "The certificate was revoked, enrolling a new one from the onboarding VLAN"
  rm -f "$DOT1X_DIR/device.crt"
  if [ -f "$EAP_CONFIG" ]; then
    mv "$EAP_CONFIG" "$EAP_CONFIG.revoked"
    leave_eap_tls
  fi
fi

# 1. Already on EAP-TLS: keep wpa_supplicant running, nothing else to do while authorized
if [ -f "$EAP_CONFIG" ]; then
  systemctl is-active --quiet "$WPA_SERVICE" || systemctl start "$WPA_SERVICE"
  if authorized; then
    if [ ! -f "$AUTHORIZED_MARKER" ]; then
      on_authorized
      exit 0
    fi
    case "$(nmcli -t -f CONNECTIVITY general)" in
      portal)
        # Waiting for the sign-in: open the window once the desktop session runs, or again if it was closed.
        # After the sign-in the short onboarding lease moves the address to the working VLAN within seconds.
        open_portal_browser
        # Checked again soon, so the window closes shortly after the sign-in
        exit 1
        ;;
      limited|none)
        # The new address lands on the onboarding VLAN, where the connectivity check finds the portal
        if address_is_stale; then
          renew_stale_address
          exit 1
        fi
        # The last check may have run before the new VLAN reached the internet; ask again instead of waiting for the next one
        nmcli networking connectivity check >/dev/null 2>&1
        ;;
    esac
    exit 0
  fi
  log "Common name $COMMON_NAME, interface $INTERFACE"
  forget_authorization
  # No address can be renewed here: while wpa_supplicant keeps trying, the switch neither authorizes the port nor
  # falls back to MAC authentication, so only leaving 802.1X opens the onboarding VLAN, its OCSP and SCEP
  if wait_for_authorization; then
    on_authorized
    exit 0
  fi
  fall_back_to_mab
fi

# 2. On the onboarding VLAN: enroll unless a valid certificate is already stored
log "Common name $COMMON_NAME, interface $INTERFACE"
# At boot the link comes up after this service starts, so wait for it instead of giving up until the next run
if ! wait_for_address; then
  log "FAIL: no cable or no address on $INTERFACE"
  exit 1
fi
if ! certificate_is_valid; then
  log "Enrolling: no valid certificate in $DOT1X_DIR"
  # The switch may have moved the port to another VLAN without a link change; renewing only then keeps a working
  # connection intact while the frequent retries run
  if ! enroll; then
    log "FAIL: enrollment failed"
    if address_is_stale; then
      renew_stale_address
    fi
    exit 1
  fi
elif switch_failed_recently; then
  log "EAP-TLS refused us less than ${SWITCH_RETRY_AFTER}s ago, staying on the onboarding VLAN"
  exit 1
elif [ -f "$SWITCH_REFUSED" ]; then
  log "Retrying EAP-TLS with the same certificate: it is still valid and not revoked"
else
  log "Reusing the certificate in $DOT1X_DIR"
fi

# 3. Switch to EAP-TLS
write_eap_config
log "Starting 802.1X on $INTERFACE"
systemctl restart "$WPA_SERVICE"
if wait_for_authorization; then
  on_authorized
  exit 0
fi
fall_back_to_mab
exit 1
