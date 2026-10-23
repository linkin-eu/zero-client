# The wired port: 802.1X through wpa_supplicant, the fallback to MAC authentication and the address.

cable_plugged() {
  [ "$(cat "/sys/class/net/$INTERFACE/carrier" 2>/dev/null)" = 1 ]
}

dot1x_status() {
  bounded 5 wpa_cli -i "$INTERFACE" status 2>/dev/null
}

# full, portal or none, from the same probe NetworkManager uses, but with a short time limit: through an address
# from the old VLAN NetworkManager's own check only gives up after about 20 s. One failed request is retried,
# since a single lost request is common and would otherwise read as an outage.
network_state() {
  local status attempt
  for attempt in 1 2; do
    status=$(bounded 5 curl -s -o /dev/null -m "$PROBE_TIMEOUT" -w "%{http_code}" "$CONNECTIVITY_URL" 2>/dev/null)
    case "$status" in
      204) echo full; return ;;
      000|"") sleep 1 ;;
      # PacketFence answers any page on the onboarding VLAN with its portal (a redirect or the page itself)
      *) echo portal; return ;;
    esac
  done
  echo none
}

# Whether PacketFence answers. It does on both VLANs, unlike the internet (working VLAN only) and ARP to the
# gateway (silent on the onboarding VLAN), so an answer proves the address works on the VLAN the port is on.
packetfence_reachable() {
  local status
  status=$(bounded 5 curl -sk -o /dev/null -m "$PROBE_TIMEOUT" -w "%{http_code}" "$OCSP_URL" 2>/dev/null)
  [ -n "$status" ] && [ "$status" != 000 ]
}

# none, valid or stale. PacketFence moves the port to another VLAN without a link change (CoA when a registration
# expires or is removed), so an address from the old VLAN can stay configured and reach nothing. Reaching the
# portal or the internet proves the address works; without either (an internet outage, or the old VLAN's address)
# PacketFence decides.
address_state() {
  local network=$1
  if ! bounded 5 ip -4 -o address show dev "$INTERFACE" scope global | grep -q inet; then
    echo none
  elif [ "$network" = full ] || [ "$network" = portal ] || packetfence_reachable; then
    echo valid
  else
    echo stale
  fi
}

# Reactivating the connection makes NetworkManager ask DHCP again and rerun the connectivity check.
# Without a link NetworkManager cannot activate the netplan connection and creates a new one instead, which it
# writes back into /etc/netplan, so nothing is done then: NetworkManager reconnects by itself once the link is up.
# When no DHCP server answers nmcli would wait the whole DHCP timeout; the activation goes on after it returns.
renew_address() {
  cable_plugged || return 0
  bounded 20 nmcli --wait 15 device connect "$INTERFACE" >/dev/null 2>&1
}

# A renewal drops the connection for a moment, so renewals are spaced out and can never turn into a loop.
# A link bounce counts as one, since NetworkManager then asks DHCP on its own.
renew_address_if_due() {
  [ "$fact_address" = valid ] && return 0
  if [ -f "$ADDRESS_RENEWED" ] && [ "$(seconds_since_modified "$ADDRESS_RENEWED")" -lt $RENEW_ADDRESS_AFTER ]; then
    return 0
  fi
  touch "$ADDRESS_RENEWED"
  log "Renewing the $fact_address address on $INTERFACE"
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

start_dot1x() {
  log "Starting 802.1X on $INTERFACE with certificate $(certificate_serial)"
  write_eap_config
  rm -f "$UNAUTHORIZED_SINCE"
  bounded 30 systemctl restart "$WPA_SERVICE"
}

# Stopping wpa_supplicant logs the port off. Without a link change the switch would keep the port as it was, so the
# link is dropped for a moment: the switch then authenticates the port from scratch, this time through MAB, and
# NetworkManager asks DHCP again by itself.
leave_dot1x() {
  bounded 30 systemctl stop "$WPA_SERVICE"
  rm -f "$AUTHORIZED_MARKER"
  close_portal_window
  bounded 5 ip link set "$INTERFACE" down
  sleep 3
  bounded 5 ip link set "$INTERFACE" up
  touch "$ADDRESS_RENEWED"
}

# A refusal while OCSP still reports the certificate good is a policy decision: the same certificate is
# tried again after SWITCH_RETRY_AFTER, and only an invalid, expired or revoked one is replaced
leave_refused() {
  log "802.1X refused, falling back to the onboarding VLAN"
  # A pulled cable is not a refusal, so it does not delay the next attempt
  cable_plugged && touch "$SWITCH_REFUSED"
  leave_dot1x
}

# The check NetworkManager ran right after a VLAN change may have come before the internet was reachable
recheck_connectivity() {
  bounded 20 nmcli networking connectivity check >/dev/null 2>&1
}
