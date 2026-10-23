# Journal output of dot1x-enroll. The controller logs each state change with the facts behind it; a failing
# action is logged once per state, so a retry every few seconds does not flood the journal (or wear the stick),
# and again after REPEAT_LOG_AFTER while it keeps failing.

REPEAT_LOG_AFTER=600
last_failure=""
last_failure_at=0

log() {
  echo "[DOT1X-ENROLL] $*"
}

log_failure() {
  local now
  now=$(date +%s)
  if [ "$*" != "$last_failure" ] || [ $((now - last_failure_at)) -ge $REPEAT_LOG_AFTER ]; then
    log "FAIL: $*"
    last_failure="$*"
    last_failure_at=$now
  fi
}

# A new state starts with a clean slate, so its first failure is always logged
forget_failures() {
  last_failure=""
  last_failure_at=0
}

seconds_since_modified() {
  echo $(( $(date +%s) - $(date -r "$1" +%s) ))
}

# Every external command runs with a time limit, so none can hold the controller; the systemd watchdog
# restarts it should anything else stall
bounded() {
  local seconds=$1
  shift
  timeout --kill-after=3 "$seconds" "$@"
}

# What the controller is doing now, so a run stopped by the watchdog shows where it stood
step() {
  echo "$*" > "$STEP_FILE"
}

