#!/usr/bin/env bash
# Checks the decisions of dot1x-enroll (dot1x-enroll/lib/decide.sh) and its address check (lib/port.sh) against the
# scenarios seen on real thin clients, without a device. Run before every upload: bash tests/dot1x-decide-test.sh

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$REPO_DIR/dot1x-enroll/lib/decide.sh"

CONNECT_TIMEOUT=60
REJECTED_AFTER=15
SWITCH_RETRY_AFTER=60

passed=0
failed=0

# A healthy device on the working network; each check changes only the facts that matter to it
reset_facts() {
  fact_link=up
  fact_mode=dot1x
  fact_auth=authorized
  fact_unauthorized_for=0
  fact_eap_failed=no
  fact_address=valid
  fact_network=full
  fact_certificate=valid
  fact_revoked=no
  fact_refused_ago=999999
  fact_previous_state=WORKING
}

# check "<name>" "<state> <action> <window>" fact=value ...
check() {
  local name=$1 expected=$2 assignment
  shift 2
  reset_facts
  for assignment in "$@"; do
    eval "fact_${assignment%%=*}=\"${assignment#*=}\""
  done
  decide
  local actual="$decision_state $decision_action $decision_window"
  if [ "$actual" = "$expected" ]; then
    passed=$((passed + 1))
  else
    failed=$((failed + 1))
    echo "FAIL $name"
    echo "     expected: $expected"
    echo "     actual:   $actual ($decision_reason)"
  fi
}

echo "== First boot of a new stick"
check "no address yet on the onboarding VLAN" "MAB_ADDRESS renew_address_if_due closed" \
  mode=mab certificate=missing address=none network=none previous_state=
check "onboarding VLAN with an address: enroll" "ENROLLING enroll_certificate closed" \
  mode=mab certificate=missing address=valid network=portal
check "certificate issued: start 802.1X" "STARTING_DOT1X start_dot1x closed" \
  mode=mab address=valid network=portal previous_state=ENROLLING
check "802.1X starting: no window, no address action" "CONNECTING none closed" \
  auth=unauthorized unauthorized_for=5 address=unknown previous_state=STARTING_DOT1X
check "authorized on the onboarding VLAN: a fresh portal window" "PORTAL none fresh" \
  network=portal previous_state=CONNECTING
check "still at the portal: keep the window open" "PORTAL none open" \
  network=portal previous_state=PORTAL
check "after the sign-in the VLAN changed: renew, leave the window" "ADDRESS renew_address_if_due keep" \
  address=stale network=portal previous_state=PORTAL
check "working network: window closed" "WORKING none closed" \
  previous_state=ADDRESS

echo "== Revoked certificate, node still registered"
check "OCSP reports it revoked" "REVOKED drop_revoked_certificate closed"  revoked=yes
check "back on the onboarding VLAN: enroll again" "ENROLLING enroll_certificate closed" \
  mode=mab certificate=missing network=portal previous_state=REVOKED
check "new certificate: start 802.1X" "STARTING_DOT1X start_dot1x closed" mode=mab previous_state=ENROLLING
check "registered node: the port moves to the working VLAN" "ADDRESS renew_address_if_due keep" \
  address=stale network=portal previous_state=CONNECTING
check "working again without a portal" "WORKING none closed" previous_state=ADDRESS

echo "== Revoked certificate and deleted node: RADIUS refuses before OCSP can be reached"
check "refused but OCSP unreachable: wait" "CONNECTING none closed" \
  auth=unauthorized unauthorized_for=30 address=unknown revoked=unknown
check "unauthorized for 60 s: leave 802.1X" "REFUSED leave_refused closed" \
  auth=unauthorized unauthorized_for=60 address=unknown revoked=unknown previous_state=CONNECTING
check "on MAB, address not there yet: back off, renew when due" "BACKOFF renew_address_if_due closed" \
  mode=mab address=none revoked=unknown refused_ago=5 network=none previous_state=REFUSED
check "onboarding VLAN reaches OCSP: revoked" "REVOKED drop_revoked_certificate closed" \
  mode=mab revoked=yes refused_ago=20 network=portal previous_state=BACKOFF
check "enroll a new certificate" "ENROLLING enroll_certificate closed" \
  mode=mab certificate=missing refused_ago=21 network=portal previous_state=REVOKED
check "a new certificate is not held back by the old refusal" "STARTING_DOT1X start_dot1x closed" \
  mode=mab refused_ago=999999 network=portal previous_state=ENROLLING
check "unregistered node: portal with Google" "PORTAL none fresh" network=portal previous_state=CONNECTING

echo "== Registration expires (CoA without a link change)"
check "old working address, nothing answers" "ADDRESS renew_address_if_due keep" \
  address=stale network=limited previous_state=WORKING
check "onboarding address: portal" "PORTAL none fresh" network=portal previous_state=ADDRESS

echo "== 802.1X refused by policy while the certificate is good"
check "refusal" "REFUSED leave_refused closed" auth=unauthorized unauthorized_for=65 address=unknown
check "pause before the next attempt" "BACKOFF renew_address_if_due closed" \
  mode=mab refused_ago=10 network=portal previous_state=REFUSED
check "try the same certificate again" "STARTING_DOT1X start_dot1x closed" \
  mode=mab refused_ago=61 network=portal previous_state=BACKOFF

echo "== A short failure followed by success never counts as a refusal"
check "unauthorized for 20 s" "CONNECTING none closed" auth=unauthorized unauthorized_for=20 address=unknown
check "authorized again" "WORKING none closed" previous_state=CONNECTING

echo "== Explicit rejection by RADIUS (EAP failure) is acted on after 15 s, silence after 60 s"
check "rejected 5 s ago: may still be a brief failure" "CONNECTING none closed" \
  auth=unauthorized eap_failed=yes unauthorized_for=5 address=unknown
check "rejected for 15 s: leave 802.1X" "REFUSED leave_refused closed" \
  auth=unauthorized eap_failed=yes unauthorized_for=15 address=unknown previous_state=CONNECTING
check "no answer for 30 s: keep waiting" "CONNECTING none closed" \
  auth=unauthorized eap_failed=no unauthorized_for=30 address=unknown
check "no answer for 60 s: leave 802.1X" "REFUSED leave_refused closed" \
  auth=unauthorized eap_failed=no unauthorized_for=60 address=unknown previous_state=CONNECTING

echo "== Link down, sleep and the MAB-only cases"
check "cable pulled while working" "NO_LINK none closed" link=down address=unknown
check "cable pulled at the portal" "NO_LINK none closed" link=down network=portal previous_state=PORTAL
check "no link on MAB without a certificate" "NO_LINK none closed" link=down mode=mab certificate=missing

echo "== Link back: 802.1X starts again, since wpa_supplicant would not and the switch could fall back to MAB"
check "cable back, wpa_supplicant still reports its old session (23.10 13:53 stuck on MAB)" \
  "STARTING_DOT1X start_dot1x closed" previous_state=NO_LINK network=portal
check "woken up, still reported authorized" "STARTING_DOT1X start_dot1x closed" previous_state=NO_LINK
check "cable back after long: no refusal from the time it was out" "STARTING_DOT1X start_dot1x closed" \
  auth=unauthorized unauthorized_for=300 address=unknown previous_state=NO_LINK
check "a revoked certificate is still dropped first" "REVOKED drop_revoked_certificate closed" \
  revoked=yes previous_state=NO_LINK
check "after the restart: the usual wait for 802.1X" "CONNECTING none closed" \
  auth=unauthorized unauthorized_for=2 address=unknown previous_state=STARTING_DOT1X
check "working VLAN through MAB without a certificate: SCEP unreachable, keep trying" \
  "ENROLLING enroll_certificate closed" mode=mab certificate=missing network=full
check "working VLAN without internet: recheck, no window" "NO_INTERNET recheck_connectivity closed" network=limited
check "a revocation of an invalid certificate is ignored" "ENROLLING enroll_certificate closed" \
  mode=mab certificate=invalid revoked=yes network=portal

echo "== Network and address probes (lib/port.sh) with stand-ins for ip and curl"
source "$REPO_DIR/dot1x-enroll/lib/port.sh"
INTERFACE=eno1
PROBE_TIMEOUT=3
CONNECTIVITY_URL=http://connectivity-check.ubuntu.com/
OCSP_URL=https://packetfence.example/pki/ocsp
# The stand-ins below are shell functions, which the real time limit (timeout) cannot run
bounded() {
  shift
  "$@"
}
sleep() { :; }
has_address=yes
ip() {
  case "$*" in
    *"address show"*) [ "$has_address" = yes ] && echo "2: eno1    inet 10.0.0.5/24 scope global eno1" ;;
  esac
}
# The internet probe answers from a list, one answer per request; curl runs in a subshell, so the position is
# kept in a file
probe_dir=$(mktemp -d)
connectivity_answers() {
  printf '%s\n' "$@" > "$probe_dir/answers"
  echo 1 > "$probe_dir/next"
}
packetfence_answer=000
curl() {
  local next
  case "$*" in
    *"$CONNECTIVITY_URL"*)
      next=$(cat "$probe_dir/next")
      printf '%s' "$(sed -n "${next}p" "$probe_dir/answers" | grep . || echo 000)"
      echo $((next + 1)) > "$probe_dir/next"
      ;;
    *"$OCSP_URL"*) printf '%s' "$packetfence_answer" ;;
  esac
}
check_probe() {
  local name=$1 expected=$2 actual=$3
  if [ "$actual" = "$expected" ]; then
    passed=$((passed + 1))
  else
    failed=$((failed + 1))
    echo "FAIL $name: expected $expected, got $actual"
  fi
}
connectivity_answers 204
check_probe "internet answers 204" full "$(network_state)"
connectivity_answers 302
check_probe "PacketFence redirects to its portal" portal "$(network_state)"
connectivity_answers 200
check_probe "PacketFence serves its portal page" portal "$(network_state)"
connectivity_answers 000 204
check_probe "one lost request, then 204 (the overnight NO_INTERNET blips)" full "$(network_state)"
connectivity_answers 000 000
check_probe "no answer twice" none "$(network_state)"

has_address=yes packetfence_answer=400
check_probe "internet reachable" valid "$(address_state full)"
check_probe "onboarding VLAN, portal reached" valid "$(address_state portal)"
check_probe "no internet, but PacketFence answers: the address works" valid "$(address_state none)"
packetfence_answer=000
check_probe "nothing answers: the address belongs to the old VLAN (22.10 09:29 took 48 s to see)" stale "$(address_state none)"
has_address=no
check_probe "no address" none "$(address_state portal)"
rm -rf "$probe_dir"

echo "== Check rhythm (next_interval)"
FAST_INTERVAL=2
ACTIVE_INTERVAL=10
WORKING_INTERVAL=20
STEADY_INTERVAL=60
STEADY_AFTER=600
check_interval() {
  local name=$1 expected=$2 actual
  actual=$(next_interval "$3" "$4")
  if [ "$actual" = "$expected" ]; then
    passed=$((passed + 1))
  else
    failed=$((failed + 1))
    echo "FAIL $name: expected $expected s, got $actual s"
  fi
}
check_interval "802.1X just started: portal seconds after authorization (22.10 15:25 waited 8 s)" 2 STARTING_DOT1X 0
check_interval "waiting for 802.1X" 2 CONNECTING 30
check_interval "link bounced: address seconds after the link is back" 2 NO_LINK 5
check_interval "working" 20 WORKING 5000
check_interval "at the portal" 10 PORTAL 30
check_interval "enrolling" 10 ENROLLING 30
check_interval "cable out for long: no need to look every 2 s" 60 NO_LINK 900
check_interval "SCEP down for long: spare PacketFence" 60 ENROLLING 900

echo "== A new certificate clears the refusal of the old one (lib/cert.sh, 22.10 15:19 lost 33 s in BACKOFF)"
test_dir=$(mktemp -d)
DOT1X_DIR=$test_dir
SWITCH_REFUSED=$test_dir/switch-refused
OCSP_CACHE=$test_dir/ocsp
SCEP_TIMEOUT=30
COMMON_NAME=zero-test
source "$REPO_DIR/dot1x-enroll/lib/cert.sh"
log() { :; }
log_failure() { :; }
fetch_ca_certificate() { return 0; }
timeout() { shift; "$@"; }
scepclient() { touch "$DOT1X_DIR/device.key" "$DOT1X_DIR/device.crt"; }
certificate_state() { echo valid; }
certificate_serial() { echo 50; }
openssl() { echo "notAfter=Oct 22 00:00:00 2029 GMT"; }
touch "$SWITCH_REFUSED"
if enroll_certificate && [ ! -f "$SWITCH_REFUSED" ]; then
  passed=$((passed + 1))
else
  failed=$((failed + 1))
  echo "FAIL a successful enrollment must remove $SWITCH_REFUSED"
fi
rm -rf "$test_dir"

echo "== 802.1X facts (lib/facts.sh): a rejected port is not authorized, even while wpa_supplicant still says so"
fact_test_dir=$(mktemp -d)
UNAUTHORIZED_SINCE=$fact_test_dir/unauthorized-since
SWITCH_REFUSED=$fact_test_dir/switch-refused
STEP_FILE=$fact_test_dir/step
source "$REPO_DIR/dot1x-enroll/lib/log.sh"
source "$REPO_DIR/dot1x-enroll/lib/facts.sh"
bounded() { shift; "$@"; }
cable_plugged() { return 0; }
systemctl() { return 0; }
network_state() { echo full; }
address_state() { echo valid; }
certificate_state() { echo valid; }
revocation_state() { echo no; }
wpa_status=""
dot1x_status() { printf '%s\n' "$wpa_status"; }
check_auth() {
  local name=$1 expected=$2
  gather_facts
  if [ "$fact_auth $fact_eap_failed" = "$expected" ]; then
    passed=$((passed + 1))
  else
    failed=$((failed + 1))
    echo "FAIL $name: expected auth/eap_failed '$expected', got '$fact_auth $fact_eap_failed'"
  fi
}
wpa_status=$'Supplicant PAE state=AUTHENTICATED\nsuppPortStatus=Authorized\nEAP state=SUCCESS'
check_auth "authorized" "authorized no"
wpa_status=$'Supplicant PAE state=HELD\nsuppPortStatus=Authorized\nEAP state=FAILURE'
check_auth "rejected, still reported authorized (22.10 15:49 renewed through a closed port)" "unauthorized yes"
wpa_status=$'Supplicant PAE state=CONNECTING\nsuppPortStatus=Unauthorized\nEAP state=IDLE'
check_auth "still trying" "unauthorized no"

echo "== Right after the link is back the network is not probed: 802.1X starts again at once"
check_probed() {
  local name=$1 expected=$2
  gather_facts
  if [ "$fact_network" = "$expected" ]; then
    passed=$((passed + 1))
  else
    failed=$((failed + 1))
    echo "FAIL $name: expected network '$expected', got '$fact_network'"
  fi
}
wpa_status=$'Supplicant PAE state=AUTHENTICATED\nsuppPortStatus=Authorized\nEAP state=SUCCESS'
fact_previous_state=NO_LINK
check_probed "link back, old authorization still reported: no probe (23.10 14:03 lost 10 s)" none
fact_previous_state=WORKING
check_probed "working: the network is probed" full
rm -rf "$fact_test_dir"

echo
echo "passed: $passed  failed: $failed"
[ "$failed" -eq 0 ]
