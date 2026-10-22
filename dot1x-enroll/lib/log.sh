# Journal output of dot1x-enroll. A failure retried every few seconds would write the same lines on every run,
# so a run's messages reach the journal only when they differ from the previous run's, or again after
# REPEAT_LOG_AFTER while the problem lasts; the skipped repeats are counted, so a loop still shows.
# Each line keeps the time it happened at, as it is printed at the end of the run.

LAST_RUN_MESSAGES=/run/dot1x-enroll-last-run
SKIPPED_REPEATS=/run/dot1x-enroll-skipped-repeats
REPEAT_LOG_AFTER=600
run_messages=""
run_log=""

# Used by the other helpers too, which is why it lives in the first file loaded
seconds_since_modified() {
  echo $(( $(date +%s) - $(date -r "$1" +%s) ))
}

log() {
  run_messages+="$*"$'\n'
  run_log+="[DOT1X-ENROLL] $(date +%T) $*"$'\n'
}

flush_log() {
  local previous="" skipped=0
  [ -f "$LAST_RUN_MESSAGES" ] && previous=$(cat "$LAST_RUN_MESSAGES")
  [ -f "$SKIPPED_REPEATS" ] && skipped=$(cat "$SKIPPED_REPEATS")
  if [ "$(printf '%s' "$run_messages")" != "$previous" ] \
    || { [ -n "$run_messages" ] && [ "$(seconds_since_modified "$LAST_RUN_MESSAGES")" -ge $REPEAT_LOG_AFTER ]; }; then
    if [ "$skipped" -gt 0 ]; then
      echo "[DOT1X-ENROLL] $(date +%T) The previous messages repeated $skipped more times"
    fi
    printf '%s' "$run_log"
    printf '%s' "$run_messages" > "$LAST_RUN_MESSAGES"
    echo 0 > "$SKIPPED_REPEATS"
  elif [ -n "$run_messages" ]; then
    echo $((skipped + 1)) > "$SKIPPED_REPEATS"
  fi
}
