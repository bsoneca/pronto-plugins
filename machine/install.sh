#!/bin/sh
# Installs the cue memory budget on this machine, once, and again after a change here: the cue
# wrapper, slot.ts beside it (the harness's tests/slot.ts, the same file as every app's) and the
# watchdog, in
# ~/.local/share/pronto/cue-budget; that folder in the global mise config's env._.path, which mise
# puts ahead of every tool, so every `cue` run through mise on the machine (every app, every
# repository, Studio's builds and the CI runners alike, with nothing in any app) is the wrapper;
# and the watchdog's launchd job, dev.pronto.cue-watchdog, every 10 s. README.md says how they work.
#
#   bin/pronto-machine install            install or update (this file)
#   bin/pronto-machine remove             take it all out again
set -eu
here=$(cd "$(dirname "$0")" && pwd)
dest="$HOME/.local/share/pronto/cue-budget"
mise_config=${MISE_GLOBAL_CONFIG_FILE:-$HOME/.config/mise/config.toml}
label=dev.pronto.cue-watchdog
plist="$HOME/Library/LaunchAgents/$label.plist"
line="_.path = [\"$dest\"]"

if [ "${1:-}" = --remove ]; then
  launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
  rm -f "$plist"
  if [ -f "$mise_config" ]; then grep -vxF "$line" "$mise_config" > "$mise_config.tmp" && mv "$mise_config.tmp" "$mise_config"; fi
  rm -rf "$dest"
  echo "cue-budget: removed"
  exit 0
fi

mkdir -p "$dest" "$HOME/Library/Logs/pronto" "$(dirname "$mise_config")"
# Each copied aside and renamed into place: a cue or a pass running from the old one reads it whole.
put() { cp "$1" "$dest/.$2.new" && chmod "$3" "$dest/.$2.new" && mv "$dest/.$2.new" "$dest/$2"; }
put "$here/cue" cue 755
put "$here/watchdog.sh" watchdog.sh 755
put "$here/vetted.ts" vetted.ts 644
put "$here/slot.ts" slot.ts 644

# The global mise config: its [env] gets the wrapper's folder on the PATH.
if ! grep -qxF "$line" "$mise_config" 2>/dev/null; then
  if [ ! -s "$mise_config" ]; then
    printf '[env]\n%s\n' "$line" > "$mise_config"
  elif grep -qE '^_\.path|^_ *=|^\[env\._' "$mise_config" || ! grep -qx '\[env\]' "$mise_config"; then
    echo "cue-budget: $mise_config has its own env PATH or no [env] table; add this under [env] by hand: $line" >&2
    exit 1
  else
    awk -v l="$line" '{ print } $0 == "[env]" { print l }' "$mise_config" > "$mise_config.tmp" && mv "$mise_config.tmp" "$mise_config"
  fi
fi

sed -e "s|__DIR__|$dest|g" -e "s|__HOME__|$HOME|g" "$here/$label.plist" > "$plist"
launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
# bootout returns before the job is gone: bootstrap again until it takes.
for _ in 1 2 3 4 5; do launchctl bootstrap "gui/$(id -u)" "$plist" 2>/dev/null && break; sleep 1; done
launchctl print "gui/$(id -u)/$label" > /dev/null
echo "cue-budget: installed in $dest; mise's PATH from $mise_config; watchdog $label every 10 s, its log ~/Library/Logs/pronto/cue-watchdog.log"
