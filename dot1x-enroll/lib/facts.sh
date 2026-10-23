# Facts for lib/decide.sh, gathered in a few seconds and without waiting for anything to change.
# Slow or unreliable probes run only when the decision can use them: ARP and OCSP need an open port.

gather_facts() {
  step "facts: link and 802.1X"
  fact_link=down
  cable_plugged && fact_link=up

  fact_mode=mab
  bounded 10 systemctl is-active --quiet "$WPA_SERVICE" && fact_mode=dot1x

  fact_auth=unauthorized
  fact_unauthorized_for=0
  fact_eap_failed=no
  if [ "$fact_mode" = dot1x ]; then
    local status
    status=$(dot1x_status)
    # RADIUS rejected us: the supplicant waits in HELD with the EAP method failed, instead of still trying
    if grep -qxE "Supplicant PAE state=HELD|EAP state=FAILURE" <<< "$status"; then
      fact_eap_failed=yes
    fi
    # After a rejection wpa_supplicant can still report the port authorized for a while, though the switch has
    # closed it; counting it as unauthorized keeps the controller from renewing an address through a closed port
    if grep -qx "suppPortStatus=Authorized" <<< "$status" && [ "$fact_eap_failed" = no ]; then
      fact_auth=authorized
      rm -f "$UNAUTHORIZED_SINCE"
    else
      [ -f "$UNAUTHORIZED_SINCE" ] || touch "$UNAUTHORIZED_SINCE"
      fact_unauthorized_for=$(seconds_since_modified "$UNAUTHORIZED_SINCE")
    fi
  else
    rm -f "$UNAUTHORIZED_SINCE"
  fi

  # While 802.1X is not authorized the port is closed, so nothing on the network can answer
  local port_open=no
  if [ "$fact_link" = up ] && { [ "$fact_mode" = mab ] || [ "$fact_auth" = authorized ]; }; then
    port_open=yes
  fi

  # Through a closed port every probe could only time out
  step "facts: network"
  fact_network=none
  [ "$port_open" = yes ] && fact_network=$(network_state)

  step "facts: address"
  fact_address=unknown
  [ "$port_open" = yes ] && fact_address=$(address_state "$fact_network")

  step "facts: certificate"
  fact_certificate=$(certificate_state)

  # OCSP answers on both VLANs; when it cannot be reached the answer is simply unknown
  step "facts: revocation"
  fact_revoked=unknown
  if [ "$fact_certificate" = valid ] && [ "$port_open" = yes ]; then
    fact_revoked=$(revocation_state)
  fi

  fact_refused_ago=999999
  [ -f "$SWITCH_REFUSED" ] && fact_refused_ago=$(seconds_since_modified "$SWITCH_REFUSED")
}

# One line for the journal, so each state change shows what it was based on
facts_summary() {
  echo "link=$fact_link mode=$fact_mode auth=$fact_auth eap_failed=$fact_eap_failed address=$fact_address network=$fact_network" \
    "certificate=$fact_certificate revoked=$fact_revoked"
}
