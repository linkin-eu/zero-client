#!/usr/bin/env bash
# Succeeds once the device is on the working network, so the Ansible units never run behind the captive portal,
# which answers the connectivity check with its own page instead of 204.
# Images built without 802.1X have no portal to wait for, and nothing to start a failed unit again later,
# so there it always succeeds.

[ -f /etc/dot1x-enroll.conf ] || exit 0

# One lost request is common, so it is tried twice
for attempt in 1 2; do
  wget -q --tries=1 --max-redirect=0 --timeout=10 -S -O /dev/null http://connectivity-check.ubuntu.com/ 2>&1 \
    | grep -q " 204 " && exit 0
  sleep 1
done
exit 1
