# The wired port: 802.1X through wpa_supplicant, the fallback to MAC authentication and the address.

cable_plugged() {
  [ "$(cat "/sys/class/net/$INTERFACE/carrier" 2>/dev/null)" = 1 ]
}

authorized() {
  wpa_cli -i "$INTERFACE" status 2>/dev/null | grep -qx "suppPortStatus=Authorized"
}

# Without 802.1X PacketFence serves the MAB login page, so the portal window must not stay open or open again:
# a window kept across the VLAN change would reload onto that page, and later onto a dead one
forget_authorization() {
  rm -f "$AUTHORIZED_MARKER"
  close_portal_browser
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

switch_failed_recently() {
  [ -f "$SWITCH_REFUSED" ] && [ "$(seconds_since_modified "$SWITCH_REFUSED")" -lt $SWITCH_RETRY_AFTER ]
}

# The switch moves the port to another VLAN when 802.1X starts or stops, so the address must follow.
# Reactivating the connection also reruns the connectivity check that detects the captive portal.
# Without a link NetworkManager cannot activate the netplan connection and creates a new one instead, which it
# writes back into /etc/netplan; Ansible then restores the file and restarts NetworkManager. Once the link is up
# NetworkManager reconnects by itself, so the renewal is skipped while there is none.
# When no DHCP server answers, nmcli would wait the whole DHCP timeout; the activation goes on in NetworkManager
# after nmcli returns, so a short wait keeps the run responsive.
renew_address() {
  cable_plugged || return 0
  nmcli --wait 15 device connect "$INTERFACE" >/dev/null 2>&1
}

wait_for_carrier() {
  local elapsed=0
  while [ $elapsed -lt $CARRIER_TIMEOUT ]; do
    cable_plugged && return 0
    sleep 1
    elapsed=$((elapsed + 1))
  done
  return 1
}

# PacketFence moves the port to another VLAN without a link change (CoA when a registration expires or is removed),
# so the address from the old VLAN stays configured and reaches nothing. The address is current while the gateway or
# the DHCP server that leased it answers ARP: the working VLAN has a gateway, while the onboarding VLAN has no router
# but PacketFence, its DHCP server, sits on it. ARP, unlike ping, is not filtered.
address_is_stale() {
  local gateway dhcp_server neighbour
  gateway=$(ip -4 route show default dev "$INTERFACE" | awk '{print $3; exit}')
  dhcp_server=$(nmcli -t -f DHCP4 device show "$INTERFACE" 2>/dev/null \
    | sed -n 's/^DHCP4\.OPTION\[[0-9]*\]:dhcp_server_identifier = //p')
  for neighbour in $gateway $dhcp_server; do
    arping -c 2 -w 3 -I "$INTERFACE" "$neighbour" >/dev/null 2>&1 && return 1
  done
  return 0
}

# A renewal briefly drops the connection and triggers a new connectivity check, which can wake the next run at once,
# so stale-address renewals are spaced out and can never turn into a loop. Fails when it is too soon to renew again.
renew_stale_address() {
  if [ -f "$STALE_RENEWED" ] && [ "$(seconds_since_modified "$STALE_RENEWED")" -lt $RENEW_STALE_AFTER ]; then
    return 1
  fi
  touch "$STALE_RENEWED"
  log "Neither the gateway nor the DHCP server on $INTERFACE answers, renewing the address"
  renew_address
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
  forget_authorization
  ip link set "$INTERFACE" down
  sleep 3
  ip link set "$INTERFACE" up
  wait_for_carrier
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
