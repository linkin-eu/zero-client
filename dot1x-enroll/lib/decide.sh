# The decision of dot1x-enroll: reads the fact_* variables gathered by lib/facts.sh and sets decision_state,
# decision_action, decision_window and decision_reason. It has no side effects, so tests/dot1x-decide-test.sh
# checks every scenario without a device. The first matching rule wins; docs/dot1x-enroll-design.md explains them.
#
# decision_window: closed, open (open unless already open), fresh (a new window) or keep (leave it as it is).
# The window is open only while 802.1X is authorized and NetworkManager sees the portal, so the MAB login page,
# served before 802.1X, can never show.

# Seconds until the next check. Fast while a change is expected within seconds and a check is cheap: the port is
# closed there, so it needs no HTTP, ARP or OCSP. Every 20 s while working; rarely once a state lasts without progress.
next_interval() {
  local state=$1 state_age=$2
  if [ "$state" = WORKING ]; then
    echo "$WORKING_INTERVAL"
  elif [ "$state_age" -ge "$STEADY_AFTER" ]; then
    echo "$STEADY_INTERVAL"
  else
    case "$state" in
      STARTING_DOT1X|CONNECTING|NO_LINK) echo "$FAST_INTERVAL" ;;
      *) echo "$ACTIVE_INTERVAL" ;;
    esac
  fi
}

set_decision() {
  decision_state=$1
  decision_action=$2
  decision_window=$3
  decision_reason=$4
}

decide() {
  if [ "$fact_link" = down ]; then
    set_decision NO_LINK none closed "no link"
    return
  fi

  # Known only while the address reaches OCSP, which happens on both VLANs
  if [ "$fact_certificate" = valid ] && [ "$fact_revoked" = yes ]; then
    set_decision REVOKED drop_revoked_certificate closed "OCSP reports the certificate revoked"
    return
  fi

  if [ "$fact_mode" = dot1x ]; then
    # Once the link is back, wpa_supplicant still reports its session from before and starts no 802.1X of its own, so
    # the switch can authenticate the port through MAB, which PacketFence answers with the onboarding VLAN even for a
    # registered device. A restart sends an EAPOL-Start, so the port always comes back through 802.1X.
    if [ "$fact_previous_state" = NO_LINK ] && [ "$fact_certificate" = valid ]; then
      set_decision STARTING_DOT1X start_dot1x closed "link back"
      return
    fi
    # While wpa_supplicant keeps trying, the switch keeps the port closed: no address can be renewed, and
    # only leaving 802.1X opens the onboarding VLAN with its OCSP and SCEP
    if [ "$fact_auth" = unauthorized ]; then
      # An explicit rejection by RADIUS is acted on soon, after a short wait so a brief failure that is followed
      # by success (seen right after waking up) does not count; silence gets the full CONNECT_TIMEOUT
      if [ "$fact_eap_failed" = yes ] && [ "$fact_unauthorized_for" -ge "$REJECTED_AFTER" ]; then
        set_decision REFUSED leave_refused closed "RADIUS rejected 802.1X, unauthorized for ${fact_unauthorized_for}s"
      elif [ "$fact_unauthorized_for" -ge "$CONNECT_TIMEOUT" ]; then
        set_decision REFUSED leave_refused closed "802.1X unauthorized for ${fact_unauthorized_for}s"
      else
        set_decision CONNECTING none closed "802.1X not authorized yet"
      fi
      return
    fi
    # PacketFence moves the port to another VLAN without a link change, so the address must follow it.
    # The window is left alone: an address check that fails for a moment must not cut a sign-in short.
    if [ "$fact_address" != valid ]; then
      set_decision ADDRESS renew_address_if_due keep "address $fact_address after a VLAN change"
      return
    fi
    case "$fact_network" in
      portal)
        # A fresh window on entering, so the page comes from the VLAN the port is on now
        if [ "$fact_previous_state" = PORTAL ]; then
          set_decision PORTAL none open "captive portal"
        else
          set_decision PORTAL none fresh "captive portal"
        fi
        ;;
      full)
        set_decision WORKING none closed "network open"
        ;;
      *)
        # NetworkManager may have checked before the new VLAN reached the internet
        set_decision NO_INTERNET recheck_connectivity closed "network $fact_network"
        ;;
    esac
    return
  fi

  # Onboarding VLAN, reached through MAC authentication
  if [ "$fact_certificate" = valid ]; then
    if [ "$fact_refused_ago" -lt "$SWITCH_RETRY_AFTER" ]; then
      # The pause also gives OCSP time to report a revocation before 802.1X is tried again
      set_decision BACKOFF renew_address_if_due closed "802.1X refused ${fact_refused_ago}s ago"
    else
      set_decision STARTING_DOT1X start_dot1x closed "valid certificate"
    fi
    return
  fi
  if [ "$fact_address" != valid ]; then
    set_decision MAB_ADDRESS renew_address_if_due closed "address $fact_address on the onboarding VLAN"
    return
  fi
  set_decision ENROLLING enroll_certificate closed "certificate $fact_certificate"
}
