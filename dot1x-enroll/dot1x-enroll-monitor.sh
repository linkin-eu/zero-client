#!/usr/bin/env bash
# Runs dot1x-enroll for the life of the device, so a lost 802.1X session, a revoked certificate or
# a PacketFence outage at first boot recover without a reboot. dot1x-enroll prints nothing while the
# port is authorized, so the journal shows only real events.

CHECK_INTERVAL=60

while true; do
  /usr/local/bin/dot1x-enroll.sh
  sleep "$CHECK_INTERVAL"
done
