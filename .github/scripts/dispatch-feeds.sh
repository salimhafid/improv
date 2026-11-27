# Sourced by class-watch.yml. The elapsed clock belongs to this chain runner.
dispatch_feeds() {
  local now=$1 state_pushed=$2
  if [[ "$MODE" == chain && "$now" -ge "$next_full_publish" ]]; then
    # Refresh shows and seat availability even when class scanning or its
    # state push failed. A failed dispatch remains due on the next scan.
    gh workflow run scrape.yml --ref main || return 1
    next_full_publish=$(( now + 3600 ))
    echo "hourly full feed publish dispatched"
  elif [[ "$state_pushed" == true && -s "$WATCH_NEW_CLASSES_FILE" ]]; then
    gh workflow run scrape.yml --ref main -f classes_only=true || return 1
    echo "classes-only feed publish dispatched"
  else
    return 0
  fi
  # Either publish reads new_at from the state branch. An unpushed
  # detection must still request a publish once its state reaches GitHub.
  if [[ "$state_pushed" == true && -s "$WATCH_NEW_CLASSES_FILE" ]]; then
    : > "$WATCH_NEW_CLASSES_FILE"
  fi
}
