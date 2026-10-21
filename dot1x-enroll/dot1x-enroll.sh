#!/usr/bin/env bash
# Moves the wired port from the PacketFence onboarding VLAN (MAC authentication) to 802.1X EAP-TLS. The
# certificate is requested over SCEP and kept in /var/lib/dot1x-enroll; when EAP-TLS stops working the EAP
# config is moved aside and the next run enrolls again if the certificate is no longer valid, was refused,
# or is revoked. dot1x-enroll-monitor.sh runs it every minute, so the device recovers on its own.

source /etc/dot1x-enroll.conf

# PacketFence serves SCEP per template over HTTP; the CA is pinned by CA_FINGERPRINT
SCEP_URL="http://$SCEP_HOST/scep/$SCEP_TEMPLATE"
# The OCSP responder answers on both VLANs, unlike the SCEP host
OCSP_URL="https://$OCSP_HOST/pki/ocsp"

DOT1X_DIR=/var/lib/dot1x-enroll
EAP_CONFIG=$DOT1X_DIR/wpa_supplicant.conf
CONNECT_TIMEOUT=60
# After EAP-TLS refused us with the cable plugged in, the next switch waits this long, so a lasting
# RADIUS outage does not drop the onboarding connection on every run. A refusal while OCSP still reports
# the certificate as good is a policy decision, so the same certificate is retried: only an invalid,
# expired or revoked certificate is replaced (the revocation check runs on every pass).
SWITCH_RETRY_AFTER=300
SWITCH_REFUSED=$DOT1X_DIR/switch-refused

# Read by captive-portal-browser.sh: before 802.1X PacketFence serves the MAB connection profile, whose login page differs
AUTHORIZED_MARKER=/run/dot1x-enroll-authorized
DESKTOP_USER=zero

INTERFACE=$(basename "$(ls -d /sys/class/net/en* 2>/dev/null | head -n1)")
WPA_SERVICE=dot1x-supplicant@$INTERFACE
# One identity per device for the certificate and PacketFence; the hostname is shared by all thin clients
COMMON_NAME="zero-$PLANT-$(tr -d : < "/sys/class/net/$INTERFACE/address" 2>/dev/null)"

log() { echo "[DOT1X-ENROLL] $*"; }

switch_failed_recently() {
  [ -f "$SWITCH_REFUSED" ] \
    && [ $(( $(date +%s) - $(date -r "$SWITCH_REFUSED" +%s) )) -lt $SWITCH_RETRY_AFTER ]
}

cable_plugged() {
  [ "$(cat "/sys/class/net/$INTERFACE/carrier" 2>/dev/null)" = 1 ]
}

authorized() {
  wpa_cli -i "$INTERFACE" status 2>/dev/null | grep -qx "suppPortStatus=Authorized"
}

wait_for_authorization() {
  local elapsed=0
  while [ $elapsed -lt $CONNECT_TIMEOUT ]; do
    authorized && return 0
    sleep 5
    elapsed=$((elapsed + 5))
  done
  return 1
}

wait_for_address() {
  local elapsed=0
  while [ $elapsed -lt $CONNECT_TIMEOUT ]; do
    ip -4 -o address show dev "$INTERFACE" scope global | grep -q inet && return 0
    sleep 5
    elapsed=$((elapsed + 5))
  done
  return 1
}

# The switch moves the port to another VLAN when 802.1X starts or stops, so the address must follow.
# Reactivating the connection also reruns the connectivity check that detects the captive portal.
renew_address() {
  nmcli device connect "$INTERFACE" >/dev/null 2>&1
}

# Starts the portal window unless it is already open; the script itself exits when there is no portal
open_portal_browser() {
  systemctl --user --machine="$DESKTOP_USER@" is-active --quiet captive-portal-browser && return 0
  systemd-run --user --machine="$DESKTOP_USER@" --unit=captive-portal-browser --collect \
    /usr/local/bin/captive-portal-browser.sh >/dev/null 2>&1 || true
}

# The captive portal is opened only from here, once the port runs 802.1X and PacketFence serves the right login page
on_authorized() {
  log "Authorized on $INTERFACE"
  rm -f "$SWITCH_REFUSED"
  renew_address
  touch "$AUTHORIZED_MARKER"
  nmcli networking connectivity check >/dev/null 2>&1
  open_portal_browser
}

# Relies on the hardware clock, so openssl verify also checks validity dates.
certificate_is_valid() {
  [ -f "$DOT1X_DIR/device.crt" ] && [ -f "$DOT1X_DIR/device.key" ] && [ -f "$DOT1X_DIR/ca.pem" ] \
    && openssl x509 -in "$DOT1X_DIR/device.crt" -noout -subject -nameopt multiline \
      | grep -qx " *commonName *= $COMMON_NAME" \
    && openssl verify -CAfile "$DOT1X_DIR/ca.pem" "$DOT1X_DIR/device.crt" >/dev/null
}

# Only an explicit "revoked" signed by our CA counts; no answer means unknown, and the caller
# carries on as if the certificate were good.
certificate_revoked() {
  local answer
  answer=$(openssl ocsp -issuer "$DOT1X_DIR/ca.pem" -cert "$DOT1X_DIR/device.crt" -CAfile "$DOT1X_DIR/ca.pem" \
    -url "$OCSP_URL" -timeout 8 2>&1)
  grep -qx "Response verify OK" <<< "$answer" && grep -q ': revoked$' <<< "$answer"
}

# scepclient checks the CA itself but does not save it; wpa_supplicant needs it as ca_cert.
fetch_ca_certificate() {
  wget -q -T 10 --tries=1 -O "$DOT1X_DIR/ca.der" "$SCEP_URL?operation=GetCACert" || return 1
  openssl x509 -inform DER -in "$DOT1X_DIR/ca.der" -out "$DOT1X_DIR/ca.pem" || return 1
  rm -f "$DOT1X_DIR/ca.der"

  local fingerprint
  fingerprint=$(openssl x509 -in "$DOT1X_DIR/ca.pem" -noout -fingerprint -sha256 | cut -d= -f2 | tr -d :)
  if [ "${fingerprint,,}" != "${CA_FINGERPRINT,,}" ]; then
    log "FAIL: CA fingerprint $fingerprint does not match the expected one"
    rm -f "$DOT1X_DIR/ca.pem"
    return 1
  fi
}

enroll() {
  log "Enrolling $COMMON_NAME at $SCEP_URL"
  fetch_ca_certificate || return 1

  # scepclient reuses an existing key and CSR, and sends a renewal instead of an
  # enrollment when the certificate file exists, so every enrollment starts clean.
  rm -f "$DOT1X_DIR/device.key" "$DOT1X_DIR/device.crt" "$DOT1X_DIR/csr.pem" "$DOT1X_DIR/self.pem"
  # scepclient has no HTTP timeout of its own; a hung request must not stall the monitor
  timeout 120 scepclient -server-url "$SCEP_URL" -challenge "$SCEP_CHALLENGE" -ca-fingerprint "$CA_FINGERPRINT" \
    -cn "$COMMON_NAME" -private-key "$DOT1X_DIR/device.key" -certificate "$DOT1X_DIR/device.crt" || return 1
  chmod 600 "$DOT1X_DIR/device.key"
  rm -f "$DOT1X_DIR/csr.pem"
  certificate_is_valid || { log "FAIL: the issued certificate does not verify"; return 1; }
  rm -f "$SWITCH_REFUSED"
  log "Certificate issued, valid until $(openssl x509 -in "$DOT1X_DIR/device.crt" -noout -enddate | cut -d= -f2)"
}

# Every enrolled device holds a certificate from the same CA, so the RADIUS server is also checked
# by name: otherwise any such certificate could pose as the authenticator.
write_eap_config() {
  cat > "$EAP_CONFIG" <<EOF
ctrl_interface=/var/run/wpa_supplicant
ap_scan=0
network={
    key_mgmt=IEEE8021X
    eap=TLS
    eapol_flags=0
    identity="$COMMON_NAME"
    ca_cert="$DOT1X_DIR/ca.pem"
    domain_suffix_match="$RADIUS_DOMAIN"
    client_cert="$DOT1X_DIR/device.crt"
    private_key="$DOT1X_DIR/device.key"
}
EOF
}

# Stopping wpa_supplicant logs the port off; the portal must not open until 802.1X is back,
# since on the onboarding VLAN PacketFence serves the MAB profile's login page.
# The switch does not move the port on its own (no CoA from PacketFence), so the link is
# dropped to make it authenticate the port again from scratch, this time through MAB.
leave_eap_tls() {
  systemctl stop "$WPA_SERVICE"
  rm -f "$AUTHORIZED_MARKER"
  ip link set "$INTERFACE" down
  sleep 3
  ip link set "$INTERFACE" up
  renew_address
}

fall_back_to_mab() {
  log "EAP-TLS was not authorized within ${CONNECT_TIMEOUT}s, falling back to the onboarding VLAN"
  mv "$EAP_CONFIG" "$EAP_CONFIG.failed"
  # Back off only when the cable was plugged in and the switch still did not let us in
  if cable_plugged; then
    touch "$SWITCH_REFUSED"
  else
    rm -f "$SWITCH_REFUSED"
  fi
  leave_eap_tls
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
    elif [ "$(nmcli -t -f CONNECTIVITY general)" = portal ]; then
      # Still waiting for the sign-in: reopen the portal window if it was closed or crashed
      open_portal_browser
    fi
    exit 0
  fi
  log "Common name $COMMON_NAME, interface $INTERFACE"
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
  # The switch may have moved the port to another VLAN without a link change, so the next run starts with a fresh address
  enroll || { log "FAIL: enrollment failed"; renew_address; exit 1; }
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
