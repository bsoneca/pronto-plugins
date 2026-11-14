#!/bin/bash
# The hard backstop of the cue memory budget: it kills a runaway `cue` so one can never take the
# machine down. On 2026-11-05 a 128 GB Mac ran out of memory and swap when 21 cue processes
# (CUE v0.16.1) held 210 GB between them. macOS has no cgroups and does not enforce ulimit -v,
# so nothing stopped them; admission control (the budget) keeps this from happening, and this
# script catches whatever gets past it.
#
# launchd runs one pass of it every 10 seconds (dev.pronto.cue-watchdog.plist). A pass looks at
# the current user's processes whose executable is named exactly `cue` (the wrapper script runs
# under sh, so its own name is not `cue` and it is never a target) and does two things:
#   over      kills with SIGKILL every cue whose resident memory is above CUE_WATCHDOG_MAX_GB.
#   pressure  when the share of memory still available (kern.memorystatus_level) is below
#             CUE_WATCHDOG_MIN_FREE_PCT and swap in use is above CUE_WATCHDOG_MAX_SWAP_GB,
#             kills the single largest cue (when it holds over CUE_WATCHDOG_PRESSURE_MIN_GB), and at most one per pass, so the next pass sees
#             whether that was enough.
# Each kill is one line in the log, written before the kill, with the process's working
# directory and command line, so whoever lost a cue can see which one and why. It also leaves
# a marker file killed/<pid> holding the reason and the size, which the cue wrapper reads to
# tell why its child died. Markers older than a day are removed on each pass.
#
# Settings (environment, all optional):
#   CUE_WATCHDOG_MAX_GB        ceiling for one cue, in GB (default RAM - 32)
#   CUE_WATCHDOG_MIN_FREE_PCT  pressure threshold on memorystatus_level (default 10)
#   CUE_WATCHDOG_MAX_SWAP_GB   pressure threshold on swap used, in GB (default 8; macOS grows swap as it needs it)
#   CUE_WATCHDOG_PRESSURE_MIN_GB  under pressure, only a cue above this is killed (default 2)
#   CUE_WATCHDOG_LOG           log file (default ~/Library/Logs/pronto/cue-watchdog.log)
#   CUE_WATCHDOG_DIR           state directory (default ~/.cache/pronto/cue-watchdog)
#   CUE_WATCHDOG_DRY=1         log "would kill" and kill nothing
# Test hooks, used by the tests and by nothing else:
#   CUE_WATCHDOG_LEVEL         replaces the measured memorystatus_level
#   CUE_WATCHDOG_SWAP_GB_NOW   replaces the measured swap used, in GB
#   CUE_WATCHDOG_ONLY_PIDS     space-separated pids; no other process is considered
#   CUE_WATCHDOG_NAME          executable name to match instead of `cue`

PATH=/usr/bin:/bin:/usr/sbin:/sbin
# The ceiling is the memory budget itself (RAM but 32 GB, as tests/slot.ts's STACK_MEM_RESERVE): a
# cue the budget admits alone may grow to it; one past it cannot be evaluated on this machine.
max_gb=${CUE_WATCHDOG_MAX_GB:-$(( $(sysctl -n hw.memsize) / 1073741824 - ${STACK_MEM_RESERVE:-32} ))}
min_free=${CUE_WATCHDOG_MIN_FREE_PCT:-10}
max_swap=${CUE_WATCHDOG_MAX_SWAP_GB:-8}
log=${CUE_WATCHDOG_LOG:-$HOME/Library/Logs/pronto/cue-watchdog.log}
dir=${CUE_WATCHDOG_DIR:-$HOME/.cache/pronto/cue-watchdog}
name=${CUE_WATCHDOG_NAME:-cue}
only=" ${CUE_WATCHDOG_ONLY_PIDS:-} "

mkdir -p "$(dirname "$log")" "$dir/killed" || exit 1
find "$dir/killed" -type f -mtime +1 -delete 2>/dev/null

level=${CUE_WATCHDOG_LEVEL:-$(sysctl -n kern.memorystatus_level 2>/dev/null)}
level=${level:-100}
swap=${CUE_WATCHDOG_SWAP_GB_NOW:-$(sysctl -n vm.swapusage 2>/dev/null | awk '{
  for (i = 1; i <= NF; i++) if ($i == "used") { v = $(i + 2); u = substr(v, length(v)); sub(/[A-Za-z]$/, "", v)
    printf "%.2f", (u == "G" ? v : u == "T" ? v * 1024 : u == "K" ? v / 1048576 : v / 1024) } }')}
swap=${swap:-0}

# pid and RSS in KB of every candidate, largest first.
cands=$(ps -U "$(id -u)" -o pid=,rss=,comm= 2>/dev/null | awk -v n="$name" -v only="$only" '{
  c = $3; for (i = 4; i <= NF; i++) c = c " " $i
  sub(/.*\//, "", c)
  if (c == n && (only == "  " || index(only, " " $1 " "))) print $1, $2 }' | sort -k2,2nr)
[ -n "$cands" ] || exit 0

# Under pressure only a cue that holds a share of it: a small one is not why the machine swaps.
floor_kb=$(awk -v g="${CUE_WATCHDOG_PRESSURE_MIN_GB:-2}" 'BEGIN { printf "%d", g * 1048576 }')
over_kb=$(awk -v g="$max_gb" 'BEGIN { printf "%d", g * 1048576 }')
pressure=0
if [ "$(awk -v l="$level" -v m="$min_free" -v s="$swap" -v x="$max_swap" 'BEGIN { print (l < m && s > x) ? 1 : 0 }')" = 1 ]; then
  pressure=1
fi

kill_one() { # pid rss_kb reason
  local pid=$1 kb=$2 reason=$3 gb cwd cmd verb=killed
  gb=$(awk -v k="$kb" 'BEGIN { printf "%.1f", k / 1048576 }')
  # Its folder costs an lsof, which can take seconds while the machine swaps: not under pressure.
  [ "$reason" = pressure ] || cwd=$(lsof -a -p "$pid" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p' | head -n 1)
  cmd=$(ps -o command= -p "$pid" 2>/dev/null | cut -c1-300)
  [ "${CUE_WATCHDOG_DRY:-}" = 1 ] && verb="would kill"
  printf '%s %s pid=%s rss=%sGB reason=%s level=%s swap=%sGB cwd=%s cmd=%s\n' \
    "$(TZ=America/Sao_Paulo date '+%Y-%m-%d %H:%M:%S BRT')" "$verb" "$pid" "$gb" "$reason" "$level" "$swap" \
    "${cwd:-?}" "${cmd:-?}" >> "$log"
  [ "${CUE_WATCHDOG_DRY:-}" = 1 ] && return 0
  printf '%s %s\n' "$reason" "$gb" > "$dir/killed/$pid"
  kill -9 "$pid" 2>/dev/null
}

first=1
while read -r pid kb; do
  [ -n "$pid" ] || continue
  if [ "$kb" -gt "$over_kb" ]; then
    kill_one "$pid" "$kb" over
  elif [ "$first" = 1 ] && [ "$pressure" = 1 ] && [ "$kb" -gt "$floor_kb" ]; then
    kill_one "$pid" "$kb" pressure
    pressure=0
  fi
  first=0
done <<EOF2
$cands
EOF2
exit 0
