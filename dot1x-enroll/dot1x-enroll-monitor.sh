#!/usr/bin/env bash
# Runs dot1x-enroll for the life of the device, so a lost 802.1X session, a revoked certificate or
# a PacketFence outage at first boot recover without a reboot. dot1x-enroll prints nothing while the
# port is authorized, so the journal shows only real events.

CHECK_INTERVAL=60
# A failed run (no 802.1X, no address, a stale address) is retried sooner, so the device recovers quickly
RETRY_INTERVAL=15
# A failure that lasts (a wrong SCEP challenge, PacketFence down) goes back to the normal interval after
# this many quick retries, so the fleet does not keep PacketFence busy
QUICK_RETRIES=8

# The NetworkManager dispatcher sends SIGUSR1 when it detects a captive portal: the wait ends and the check
# runs at once. A wake-up that arrives during a run is kept, so one more run follows and sees the new state.
wake_requested=0
sleep_pid=""
trap 'wake_requested=1; [ -n "$sleep_pid" ] && kill "$sleep_pid" 2>/dev/null' USR1

failed_runs=0
while true; do
  wake_requested=0
  if /usr/local/bin/dot1x-enroll.sh; then
    failed_runs=0
    interval=$CHECK_INTERVAL
  else
    failed_runs=$((failed_runs + 1))
    if [ "$failed_runs" -le "$QUICK_RETRIES" ]; then
      interval=$RETRY_INTERVAL
    else
      interval=$CHECK_INTERVAL
    fi
  fi
  sleep "$interval" &
  sleep_pid=$!
  # Checked after the sleep has started, so a wake-up that came just before it is not lost
  [ "$wake_requested" -eq 1 ] && kill "$sleep_pid" 2>/dev/null
  wait "$sleep_pid"
  sleep_pid=""
done
