#!/bin/sh
# Sets pronto up in Claude Code, once (run it again any time: it changes only what is missing):
# the plugins marketplace read from this checkout, pronto's plugin installed or updated, and the
# intents allowed in your user settings, so that saying "release my-app" runs with no prompt
# (skills/pronto-intents). Claude Code lets only you grant that, so this is yours to run.
#   plugins/setup.sh
set -eu
here=$(cd "$(dirname "$0")" && pwd)
market=bsoneca-pronto-plugins
plugin=pronto-studio@$market
old=pronto-android@$market
command -v claude >/dev/null || { echo "setup: Claude Code's claude is not on the PATH" >&2; exit 1; }

# The marketplace, from this checkout: a pull is what an update brings.
known=$(claude plugin marketplace list 2>/dev/null || true)
if ! printf '%s\n' "$known" | grep -q "$here"; then
	printf '%s\n' "$known" | grep -q "$market" && claude plugin marketplace remove "$market"
	claude plugin marketplace add "$here"
fi
# pronto's plugin, which carries every skill of the marketplace; its old name is uninstalled, since
# both would load the same skills.
claude plugin list 2>/dev/null | grep -q "$old" && claude plugin uninstall "$old"
if claude plugin list 2>/dev/null | grep -q "$plugin"; then
	claude plugin update "$plugin"
else
	claude plugin install "$plugin"
fi

# The intents, allowed in your user settings (a copy of them kept beside them first).
settings=${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json
mkdir -p "$(dirname "$settings")"
[ -f "$settings" ] && cp "$settings" "$settings.before-pronto"
python3 -I - "$settings" <<'PY'
import json, os, sys
path = sys.argv[1]
s = json.load(open(path)) if os.path.exists(path) and os.path.getsize(path) else {}
allow = s.setdefault("permissions", {}).setdefault("allow", [])
added = [r for r in ["Bash(pronto release:*)", "Bash(pronto plan:*)", "Bash(pronto connect:*)", "Bash(pronto deploy:*)"] if r not in allow]
allow.extend(added)
json.dump(s, open(path, "w"), indent=2)
open(path, "a").write("\n")
print(f"setup: {len(added)} of pronto's intents allowed in {path}" if added else f"setup: pronto's intents were allowed already in {path}")
PY

echo 'setup: done. Start a new Claude Code session and say what you want, such as "release my-app".'
