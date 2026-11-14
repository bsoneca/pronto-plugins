#!/bin/sh
# Raises this Mac's System V shared memory limits, now and at every boot (PRONTO-40). Every postgres
# cluster takes one segment (its interlock), and macOS allows 32 on the whole machine
# (kern.sysv.shmmni): a full machine of stacks (gates, rehearsals, Studio's previews and published
# games) passes that, and the next database exits at start. tests/slot.ts frees the segments dead
# postgres left at every claim; this gives the live ones room. Run once per Mac, as root:
#   sudo bin/pronto-machine shm             # set, and keep at boot (this file)
#   sudo bin/pronto-machine shm --remove    # back to macOS's own limits at the next boot
set -eu
label=dev.pronto.sysv-shm
plist=/Library/LaunchDaemons/$label.plist
if [ "$(id -u)" != 0 ]; then echo "run it as root: sudo $0" >&2; exit 1; fi
if [ "${1:-}" = "--remove" ]; then
  launchctl bootout system "$plist" 2>/dev/null || true
  rm -f "$plist"
  echo "removed $plist: macOS's own limits from the next boot"
  exit 0
fi
# 256 segments of 4 MB at most, 64 a process: room for every cluster a full machine runs, with
# shmall (4 KB pages) matching shmmax times the segments a process may hold.
cat > "$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$label</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/sbin/sysctl</string>
    <string>-w</string>
    <string>kern.sysv.shmmax=4194304</string>
    <string>kern.sysv.shmmin=1</string>
    <string>kern.sysv.shmmni=256</string>
    <string>kern.sysv.shmseg=64</string>
    <string>kern.sysv.shmall=65536</string>
  </array>
  <key>RunAtLoad</key><true/>
</dict>
</plist>
PLIST
chown root:wheel "$plist"
chmod 644 "$plist"
launchctl bootout system "$plist" 2>/dev/null || true
launchctl bootstrap system "$plist"
sysctl kern.sysv.shmmni kern.sysv.shmseg
