#!/usr/bin/env bash
# Written by pronto-plugins' node/host (bin/pronto-node --host), its settings in /etc/pronto/disk-watch.env — do not edit
# Tells the operator when a filesystem of the node is filling. It runs on the host, so an eviction of every pod, a dead
# cluster or a down tunnel cannot silence it. With --dry-run it only says what it would post.
set -euo pipefail
dry=0
case "${1:-}" in
  "") ;;
  --dry-run) dry=1 ;;
  *) echo "disk-watch: unknown argument $1 (only --dry-run)" >&2; exit 2 ;;
esac
env=${DISK_WATCH_ENV:-/etc/pronto/disk-watch.env}
state=${DISK_WATCH_STATE:-/var/lib/pronto/disk-watch}
# MOUNTS (space separated), THRESHOLD_PERCENT, RENOTIFY_MINUTES and NOTIFY_URL: host.nu writes them from #Host's diskWatch.
# shellcheck disable=SC1090
. "$env"
: "${MOUNTS:?disk-watch: MOUNTS is not set in $env}" "${THRESHOLD_PERCENT:?}" "${RENOTIFY_MINUTES:?}" "${NOTIFY_URL:?}"
# A mark is dropped once the use falls this far under the threshold, so a disk hovering at the line is one crossing.
hysteresis=3
now=$(date +%s)
failed=0
seen=" "
[ "$dry" = 1 ] || mkdir -p "$state"

for path in $MOUNTS; do
  # POSIX df: the last line's fifth field is the use ("76%"), the sixth the mount point. A path df cannot read is an error,
  # never "fine": the watcher must not go quiet on a mount that moved.
  if ! line=$(df -P "$path" | tail -n 1); then echo "disk-watch: cannot read $path" >&2; failed=1; continue; fi
  read -r _ _ _ _ use mount <<<"$line"
  use=${use%\%}
  if ! [[ $use =~ ^[0-9]+$ ]]; then echo "disk-watch: cannot read the use of $path: '$line'" >&2; failed=1; continue; fi
  # Two paths on one filesystem are one disk.
  case "$seen" in *" $mount "*) continue ;; esac
  seen="$seen$mount "
  mark="$state/$(printf '%s' "$mount" | tr -c 'A-Za-z0-9' '_')"
  if [ "$use" -lt $((THRESHOLD_PERCENT - hysteresis)) ]; then
    [ "$dry" = 1 ] || rm -f "$mark"
    continue
  fi
  [ "$use" -ge "$THRESHOLD_PERCENT" ] || continue
  if [ -e "$mark" ]; then
    last=$(cat "$mark")
    if ! [[ $last =~ ^[0-9]+$ ]]; then last=0; fi
    [ $((now - last)) -ge $((RENOTIFY_MINUTES * 60)) ] || continue
  fi
  msg="$(hostname): $mount is ${use}% full (alert at ${THRESHOLD_PERCENT}%)"
  if [ "$dry" = 1 ]; then echo "would post: $msg"; continue; fi
  # The mark is written only once the post succeeded, so a failed post is tried again at the next run.
  if curl -fsS --max-time 20 -H "Title: node disk" -H "Priority: high" -d "$msg" "$NOTIFY_URL" >/dev/null; then
    printf '%s\n' "$now" >"$mark.new" && mv -f "$mark.new" "$mark"
    echo "disk-watch: posted: $msg"
  else
    echo "disk-watch: could not post: $msg" >&2
    failed=1
  fi
done
exit "$failed"
