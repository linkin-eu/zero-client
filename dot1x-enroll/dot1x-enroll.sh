#!/usr/bin/env bash
# Keeps the wired port on 802.1X EAP-TLS for the life of the device, like a Kubernetes controller: every few
# seconds, or at once when the NetworkManager dispatcher signals a change, it gathers the facts (link, 802.1X,
# address, network, certificate, revocation), lets lib/decide.sh pick one state and one short action, and does it.
# It keeps no memory of where it is in a flow, so it recovers from anything a later check can see.
# docs/dot1x-enroll-design.md explains the states.

source /etc/dot1x-enroll.conf

# PacketFence serves SCEP per template over HTTP; the CA is pinned by CA_FINGERPRINT
SCEP_URL="http://$SCEP_HOST/scep/$SCEP_TEMPLATE"
# The OCSP responder answers on both VLANs, unlike the SCEP host
OCSP_URL="https://$OCSP_HOST/pki/ocsp"
# Answers 204 on the working network; on the onboarding VLAN PacketFence answers with its portal instead
CONNECTIVITY_URL=http://connectivity-check.ubuntu.com/
PROBE_TIMEOUT=3

DOT1X_DIR=${DOT1X_DIR:-/var/lib/dot1x-enroll}
EAP_CONFIG=$DOT1X_DIR/wpa_supplicant.conf
# Last refusal of 802.1X with the cable plugged in; kept across reboots
SWITCH_REFUSED=$DOT1X_DIR/switch-refused

# DRY_RUN=1 gathers the facts and decides as usual, but only logs the actions: a shadow run beside another controller
# (with its own RUN_DIR) shows what this one would do on a real device without touching the port
DRY_RUN=${DRY_RUN:-0}
RUN_DIR=${RUN_DIR:-/run/dot1x-enroll}
UNAUTHORIZED_SINCE=$RUN_DIR/unauthorized-since
ADDRESS_RENEWED=$RUN_DIR/address-renewed
OCSP_CACHE=$RUN_DIR/ocsp
STEP_FILE=$RUN_DIR/step
# Read by captive-portal-browser.sh: before 802.1X PacketFence serves the MAB connection profile, whose login page differs
AUTHORIZED_MARKER=/run/dot1x-enroll-authorized
DESKTOP_USER=zero

# 802.1X that is not authorized after this long counts as refused; after an explicit RADIUS rejection, sooner
CONNECT_TIMEOUT=60
REJECTED_AFTER=15
# After a refusal the same valid certificate is tried again after this long
SWITCH_RETRY_AFTER=60
RENEW_ADDRESS_AFTER=30
OCSP_CHECK_EVERY=20
SCEP_TIMEOUT=30
# Checks: very often while 802.1X or the link is about to change, often while something is in progress,
# less often while working, rarely while a state lasts without progress (lib/decide.sh, next_interval)
FAST_INTERVAL=2
ACTIVE_INTERVAL=10
WORKING_INTERVAL=20
STEADY_INTERVAL=60
STEADY_AFTER=600

INTERFACE=$(basename "$(ls -d /sys/class/net/en* 2>/dev/null | head -n1)")
WPA_SERVICE=dot1x-supplicant@$INTERFACE
# One identity per device for the certificate and PacketFence; the hostname is shared by all thin clients
COMMON_NAME="zero-$PLANT-$(tr -d : < "/sys/class/net/$INTERFACE/address" 2>/dev/null)"

LIB_DIR=${LIB_DIR:-/usr/local/lib/dot1x-enroll}
source "$LIB_DIR/log.sh"
source "$LIB_DIR/facts.sh"
source "$LIB_DIR/decide.sh"
source "$LIB_DIR/cert.sh"
source "$LIB_DIR/port.sh"
source "$LIB_DIR/portal.sh"

if [ -z "$INTERFACE" ]; then
  log "FAIL: no Ethernet interface"
  exit 1
fi
mkdir -p "$DOT1X_DIR" "$RUN_DIR"
chmod 700 "$DOT1X_DIR"

# A previous controller that did not reach its sleep was stopped by the watchdog or crashed
if [ -f "$STEP_FILE" ] && [ "$(cat "$STEP_FILE")" != sleeping ]; then
  log "The previous controller stopped during: $(cat "$STEP_FILE")"
fi

# The dispatcher sends SIGUSR1 on a network change: the wait ends and the next check runs at once.
# A signal that arrives during a check is kept, so one more check follows and sees the new state.
wake_requested=0
sleep_pid=""
trap 'wake_requested=1; [ -n "$sleep_pid" ] && kill "$sleep_pid" 2>/dev/null' USR1
trap 'exit 0' TERM INT

current_state=""
state_since=$(date +%s)

while true; do
  wake_requested=0
  # Tells the systemd watchdog the loop still turns; a check that stalls is restarted (WatchdogSec)
  [ "$DRY_RUN" = 1 ] || bounded 5 systemd-notify WATCHDOG=1

  gather_facts
  fact_previous_state=$current_state
  step "deciding"
  decide

  if [ "$decision_state" != "$current_state" ]; then
    log "${current_state:-START} -> $decision_state ($decision_reason; $(facts_summary))"
    current_state=$decision_state
    state_since=$(date +%s)
    forget_failures
  fi

  if [ "$DRY_RUN" = 1 ]; then
    if [ "$decision_state $decision_action $decision_window" != "$last_dry_decision" ]; then
      log "would: action=$decision_action window=$decision_window"
      last_dry_decision="$decision_state $decision_action $decision_window"
    fi
  else
    # captive-portal-browser.sh opens nothing without it, as a second guard against the MAB login page
    if [ "$fact_mode" = dot1x ] && [ "$fact_auth" = authorized ]; then
      touch "$AUTHORIZED_MARKER"
    else
      rm -f "$AUTHORIZED_MARKER"
    fi
    step "action: $decision_action"
    [ "$decision_action" != none ] && "$decision_action"
    step "window: $decision_window"
    apply_window_decision "$decision_window"
  fi
  step sleeping

  interval=$(next_interval "$current_state" $(( $(date +%s) - state_since )))
  sleep "$interval" &
  sleep_pid=$!
  # Checked after the sleep has started, so a wake-up that came just before it is not lost
  [ "$wake_requested" -eq 1 ] && kill "$sleep_pid" 2>/dev/null
  wait "$sleep_pid"
  sleep_pid=""
done
