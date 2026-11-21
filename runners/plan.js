// runners' rules, pure: what applying a setup's plan does, given what runners.ts found in the cluster.
// runners.ts observes, asks these, then runs the steps in order; the cases are suite `runners`
// (tests/unit/runners.cue).

/**
 * The steps of an apply, in order. `seen`: whether the setup's Colima VM runs (a Colima setup's
 * only), the scale set releases already in the runners' namespace, whether the secret is there.
 * Without the secret it stops after BuildKit: no scale set registers without it.
 */
export function steps(plan, seen) {
  const out = [];
  if (plan.colima && !seen.vm) out.push({ do: 'start-vm' });
  out.push({ do: 'controller' }, { do: 'buildkit' }, { do: 'namespace' });
  if (!seen.secret) return [...out, { do: 'need-secret' }];
  const wanted = Object.keys(plan.scaleSets).sort();
  for (const name of wanted) out.push({ do: 'scale-set', name });
  // A scale set the setup no longer names: its runners would keep taking jobs.
  for (const name of [...seen.releases].sort()) if (!wanted.includes(name)) out.push({ do: 'remove', name });
  return out;
}

/** How a person creates the setup's secret: its values come from them, never from the setup. */
export function secretHelp(plan) {
  const repos = [...new Set(Object.values(plan.scaleSets).map((s) => s.githubConfigUrl.replace('https://github.com/', '')))];
  const create = `kubectl --context ${plan.context} -n ${plan.runnerNamespace} create secret generic ${plan.secret.name}`;
  if (plan.secret.kind === 'app') {
    return [
      `A GitHub App installed on ${repos.join(', ')} with Administration: read and write (repository) or Self-hosted runners: read and write (organization), then:`,
      `${create} --from-literal=github_app_id=<id> --from-literal=github_app_installation_id=<installation> --from-file=github_app_private_key=<key.pem>`,
    ];
  }
  return [
    `A fine-grained token for ${repos.join(', ')} with Administration: read and write (an organization's: Self-hosted runners: read and write), then:`,
    `read -rs t && ${create} --from-literal=github_token="$t"; unset t`,
  ];
}

/**
 * A host setup's apply, in order, runner by runner (by name): `seen[name]` says whether its folder
 * holds the runner (`installed`), its `registration` (registration() below), and whether its
 * launchd agent is the plan's and loaded (`agent`). A stale registration is undone first, since
 * config.sh refuses a registered folder, and the agent reloaded after, onto the new one.
 */
export function hostSteps(plan, seen) {
  const out = [];
  for (const name of Object.keys(plan.host).sort()) {
    const s = seen[name] ?? {};
    const r = plan.host[name];
    if (s.unknown) {
      out.push({ do: 'unknown', name });
      continue;
    }
    if (r.user) {
      out.push(...accountSteps(r, name, s));
      continue;
    }
    // A runner that has gone back to the applier's own: its daemon, if one is still loaded, goes first.
    if (s.legacyDaemon) out.push({ do: 'remove-daemon', name });
    if (!s.installed) out.push({ do: 'install', name });
    if (s.registration === 'stale') out.push({ do: 'unregister', name });
    if (s.registration !== 'current') out.push({ do: 'register', name });
    // Its hook, when it admits workflows, is in place before its agent (re)starts.
    const hook = r.hook && !s.hook;
    if (hook) out.push({ do: 'hook', name });
    if (!s.agent || hook || s.registration !== 'current') out.push({ do: 'agent', name });
  }
  return out;
}

/**
 * A runner with an account (a LaunchDaemon run as it): `seen` adds whether the `account` exists,
 * whether the runner is still registered from the applier's own folder (`oldRegistered`), whether
 * its folder is root's (`locked`), its `tools` and `hook` are in place and its `daemon` is the
 * plan's. A runner that changes account finishes its job (`drain`) and is unregistered from the old
 * folder, which is kept, before it registers again from the account's, under the same name and
 * labels, with the folder then given to root but `_work` and `_diag`; its tools and hook are in place
 * before its daemon starts, so no job runs unprobed. A daemon that was unloaded to unlock or lock
 * the folder is loaded again by the `daemon` step that follows.
 */
function accountSteps(r, name, s) {
  const out = [];
  const stale = s.registration === 'stale';
  const redo = s.registration !== 'current';
  let locked = !!s.locked;
  let drained = false;
  let bounced = false;
  const drain = () => {
    if (!drained) out.push({ do: 'drain', name });
    drained = true;
  };
  const unlock = () => {
    if (!locked) return;
    drain();
    out.push({ do: 'unlock', name });
    locked = false;
    bounced = true;
  };
  if (!s.account) out.push({ do: 'account', name });
  if (s.oldRegistered) {
    drain();
    out.push({ do: 'unregister-old', name });
  }
  if (!s.installed) {
    out.push({ do: 'install-as', name });
    locked = false;
  }
  if (stale) {
    drain();
    unlock();
    out.push({ do: 'unregister-as', name });
  }
  if (redo) {
    unlock();
    out.push({ do: 'register-as', name });
  }
  if (!locked) {
    out.push({ do: 'lock', name });
    bounced = true;
  }
  if (r.tools && !s.tools) out.push({ do: 'tools', name });
  if (!s.hook) out.push({ do: 'hook', name });
  if (!s.daemon || !s.hook || redo || bounced) out.push({ do: 'daemon', name });
  return out;
}

/** The steps that act as root or as a runner's account: all of an account's but `drain` and `unregister-old`, the applier's own. */
export const needsSudo = (step) => ['account', 'install-as', 'unregister-as', 'unlock', 'register-as', 'lock', 'tools', 'hook', 'daemon', 'remove-daemon'].includes(step.do);

/** Whether a step cuts a runner's job if it is running one: it waits for `busy: false` again right before it acts. */
const busyGated = ['unregister', 'agent', 'unregister-old', 'unregister-as', 'unlock', 'daemon', 'remove-daemon'];
export const gatedByBusy = (step) => busyGated.includes(step.do);

/**
 * A uid for each account to create, chosen once, in order, from `from` up and never one in `usedUids` or
 * `usedGids` (the account's group takes the same number): so no two accounts of a list printed or run share one.
 */
export function allocateUids(accounts, usedUids, usedGids = [], from = 510) {
  const taken = new Set([...usedUids, ...usedGids]);
  const out = {};
  let uid = from;
  for (const a of accounts) {
    while (taken.has(uid)) uid++;
    out[a.login] = uid;
    taken.add(uid);
  }
  return out;
}

/**
 * What a runner with an account is found to be, from what runners.ts could read. `f`: `sudo` (whether
 * sudo -n works), `account`, `oldRegistered`, `hookSame` and `daemonSame` (the root-owned files are
 * world-readable), `loaded`, GitHub's view of the runner (`gh`: `{status, labels}` or null), and, only
 * with sudo, what is in its folder (`found`: .runner, .path and the labels, `installed`, `locked`, `tools`).
 * Without sudo nothing in its folder is read, and none of it is guessed for a runner that already has its
 * files: online on GitHub with its labels, it is current; otherwise it is left alone (`unknown`). A runner
 * with none of its files is still to be moved.
 */
export function inspectAccount(plan, name, f) {
  const r = plan.host[name];
  const base = { account: f.account, oldRegistered: f.oldRegistered, hook: f.hookSame };
  if (f.sudo) return { ...base, installed: f.installed, registration: registration(plan, name, f.found), locked: f.locked, tools: f.tools, daemon: f.daemonSame && f.loaded };
  if (f.hookSame && f.daemonSame) {
    const online = !!f.gh && f.gh.status === 'online' && r.labels.every((l) => f.gh.labels.includes(l));
    return online ? { ...base, installed: true, registration: 'current', locked: true, tools: true, daemon: true } : { unknown: true };
  }
  return { ...base, installed: false, registration: 'none', locked: false, tools: false, daemon: false };
}

/** The token's place on stdin, never in an argument: read into ACTIONS_RUNNER_INPUT_TOKEN, which config.sh takes as --token. */
const TOKEN_IN = 'IFS= read -r ACTIONS_RUNNER_INPUT_TOKEN && export ACTIONS_RUNNER_INPUT_TOKEN';

/** A script that checks a file against a sha256 (shasum -c), as its first and its second argument after the digest. */
const CHECK = 'printf "%s  %s\\n" "$0" "$1" | shasum -a 256 -c - >/dev/null';

/** A script that refuses a binary ($0) that links a library outside /usr/lib and /System, removing it. */
const LINKS = 'out=$(otool -L "$0") || { rm -f "$0"; exit 1; }; printf "%s\\n" "$out" | tail -n +2 | while read -r lib rest; do case "$lib" in /usr/lib/*|/System/*) ;; *) echo "$0 links $lib" >&2; exit 1;; esac; done || { rm -f "$0"; exit 1; }';

/**
 * The runner's tarball ($1, the stage's bytes) copied to a root-only file, checked there against the pinned digest
 * ($0), and only then extracted, as the account ($2), into its folder ($3): what is extracted is what was checked,
 * whatever the stage becomes after.
 */
const TAR = 'set -e; t=$(mktemp); trap "rm -f $t" EXIT; cat "$1" > "$t"; printf "%s  %s\\n" "$0" "$t" | shasum -a 256 -c - >/dev/null; sudo -n -u "$2" -H tar xzf - -C "$3" < "$t"';

/** A group ($0) that must not exist yet: its gid is the account's, and a group that is there is someone's. */
const GROUP_FREE = '! dscl . -read "/Groups/$0" >/dev/null 2>&1 || { echo "group $0 exists" >&2; exit 1; }';

/** Symlinks ($0 and the rest) removed, so what is made in their place is a folder. */
const UNLINK = 'for d in "$0" "$@"; do if [ -L "$d" ]; then rm -f "$d"; fi; done';

/**
 * `lst DIR WORK DIAG`: the symlinks under DIR outside its WORK and DIAG, one `path<TAB>target` line each, sorted, and
 * a failure (never a partial list) when find or readlink fails, when a name or a link's target holds a tab or a
 * newline (they would shift the fields), or when a target names WORK or DIAG (a link into the folders the account
 * writes would have the listener run account-writable code).
 */
const LST = [
  'lst() {',
  '  d=$1; nl=$(printf "\\n_"); nl=${nl%_}; tb=$(printf "\\t"); p="$d/$2"; q="$d/$3"',
  '  bad=$(find "$d" -xdev \\( -path "$p" -o -path "$q" \\) -prune -o \\( -path "*$nl*" -o -path "*$tb*" -o -lname "*$nl*" -o -lname "*$tb*" \\) -print) || return 1',
  '  [ -z "$bad" ] || { echo "a tab or a newline in a name or a link: $bad" >&2; return 1; }',
  '  links=$(find "$d" -xdev \\( -path "$p" -o -path "$q" \\) -prune -o -type l -print) || return 1',
  '  raw=$(mktemp) || return 1',
  '  printf "%s\\n" "$links" | while IFS= read -r l; do',
  '    [ -n "$l" ] || continue',
  '    t=$(readlink "$l") || exit 1',
  '    case "$t" in *"$2"*|*"$3"*) echo "$l -> $t reaches $2 or $3" >&2; exit 1;; esac',
  '    printf "%s\\t%s\\n" "${l#"$d"/}" "$t"',
  '  done > "$raw" || { rm -f "$raw"; return 1; }',
  '  LC_ALL=C sort "$raw"; s=$?; rm -f "$raw"; return $s',
  '}',
].join('\n');

/**
 * The runner tarball's symlinks ($1, the stage's bytes), recorded root-only at install: copied to a root-only file,
 * checked there against the pinned digest ($0), extracted into a root-only scratch folder and listed (lst) into the
 * manifest ($2, in root's folder, written beside and renamed). $3 is the account's `_work`.
 */
const MANIFEST = [
  'set -e; t=$(mktemp); m=$(mktemp -d); trap "rm -rf $t $m $2.new" EXIT',
  'cat "$1" > "$t"; printf "%s  %s\\n" "$0" "$t" | shasum -a 256 -c - >/dev/null',
  'tar xzf "$t" -C "$m"',
  LST,
  'lst "$m" "$3" _diag > "$2.new"; chmod 644 "$2.new"; mv -f "$2.new" "$2"',
].join('\n');

/**
 * A runner folder ($0, its _work $1, the tarball's manifest $2) that holds, outside _work and _diag, a regular file
 * with more than one link, or any symlink but the tarball's own, each with the target the tarball gave it (lst's
 * lines must equal the manifest's): refused. The runner's own relative links (node/bin/npm and the like) are in it.
 * Everything fails closed: no manifest, a failing find, a tab or newline in a name, a link into _work or _diag.
 */
const CLEAN = [
  'r=$0; w=$1; m=$2',
  '[ -f "$m" ] && [ ! -L "$m" ] || { echo "$m: no manifest of the runner tarball" >&2; exit 1; }',
  LST,
  'now=$(mktemp) || exit 1; trap "rm -f $now" EXIT',
  'lst "$r" "$w" _diag > "$now" || exit 1',
  'out=$(find "$r" -xdev \\( -path "$r/$w" -o -path "$r/_diag" \\) -prune -o -type f -links +1 -print) || exit 1',
  '[ -z "$out" ] || { echo "$out has more than one link" >&2; exit 1; }',
  'cmp -s "$now" "$m" || { diff "$m" "$now" >&2; echo "the symlinks are not the runner tarball\'s" >&2; exit 1; }',
].join('\n');

/**
 * A runner folder ($0)'s `.path` is the plan's PATH ($1) and its `.env` (optional) holds nothing but a LANG: a hook
 * variable in it would be root's after the lock. Plain files only.
 */
const ENVCHECK = [
  'cd "$0" || exit 1',
  '[ -f .path ] && [ ! -L .path ] || { echo "$0/.path is not a plain file" >&2; exit 1; }',
  '[ ! -L .env ] && { [ ! -e .env ] || [ -f .env ]; } || { echo "$0/.env is not a plain file" >&2; exit 1; }',
  '[ "$(cat .path)" = "$1" ] || { echo "$0/.path is not the plan\'s PATH" >&2; exit 1; }',
  'if [ -e .env ]; then bad=$(grep -Ev "^LANG=[A-Za-z0-9_.@-]+\\$" .env); [ -z "$bad" ] || { echo "$0/.env has lines the plan does not render: $bad" >&2; exit 1; }; fi',
].join('\n');

/**
 * What stops an account's processes before its folder changes hands, as a runner's account could leave one behind (a
 * setsid or double fork, a cleared RUNNER_TRACKING_ID, a crontab) that bootout doesn't reach: after the daemon is
 * out and the crontab gone, the account's processes are killed (as the account: `kill -KILL -1` as root would kill
 * everything) until none is left, 3 tries; and the daemon must be gone from launchd.
 */
/**
 * `_work` and `_diag` ($2, $3) made as root with a plain `mkdir -m 700` (never install -d or -p) where nothing is
 * there, then each chowned to the account ($0, group $1) with -h. Anything there that is a symlink or not a folder
 * stops the lock (UNLINK has removed the links); a folder kept from an earlier lock is only chowned.
 */
const MAKE = 'u=$0; g=$1; shift; for d; do if [ -L "$d" ]; then echo "$d is a symlink" >&2; exit 1; elif [ ! -e "$d" ]; then mkdir -m 700 "$d" || exit 1; fi; [ -d "$d" ] || { echo "$d is not a folder" >&2; exit 1; }; chown -h "$u:$g" "$d" || exit 1; done';
const REAP = 'i=0; while pgrep -u "$0" >/dev/null; do [ $i -lt 3 ] || { echo "$0 still has processes" >&2; exit 1; }; i=$((i+1)); sudo -n -u "$0" /bin/kill -KILL -1 || true; sleep 1; done';
const GONE = '! launchctl print "system/$0" >/dev/null 2>&1 || { echo "system/$0 is still loaded" >&2; exit 1; }';

/**
 * The commands a step of a runner with an account (or of the applier's own, behind a hook) runs as root or as
 * its account, each `{argv}` (and `tolerate` when its failing is fine, `stdin` a file it reads, `token` when
 * the registration or removal token is its stdin). `ctx`: `uids` (a login's free uid, for `account`) and
 * `stage` (a folder holding the step's files: `plist` (the plan's XML), `job-started.sh`, `runner.tar.gz`, `gh`).
 * A file root installs from the stage is checked against the sha256 the plan renders before it is installed,
 * installed beside its place, checked there, and only then renamed onto it (an atomic rename in a folder of
 * root's): a staged copy edited since fails the command, and a file is never half in place.
 */
export function stepCommands(plan, name, step, ctx) {
  const r = plan.host[name];
  const root = (...argv) => ({ argv: ['sudo', '-n', ...argv] });
  const as = (...argv) => ({ argv: ['sudo', '-n', '-u', r.user, '-H', ...argv] });
  const dirOf = (p) => p.replace(/\/[^/]*$/, '');
  const sh = (dir, script, ...argv) => as('env', `PATH=${r.path}`, '/bin/sh', '-c', `cd "$0" && ${script}`, dir, ...argv);
  const bootout = () => ({ ...root('launchctl', 'bootout', `system/${r.service.label}`), tolerate: true });
  // Nothing of the account runs, and nothing can start, before its folder changes hands (REAP): the daemon out (and
  // proven out), its crontab gone, its processes killed.
  const quiesce = () => [
    bootout(),
    { ...root('crontab', '-u', r.user, '-r'), tolerate: true },
    root('/bin/sh', '-c', REAP, r.user),
    root('/bin/sh', '-c', GONE, `${r.service.label}`),
  ];
  const manifest = `${dirOf(r.dir)}/links.manifest`;
  const put = (sha, staged, dest, mode, extra = () => []) => [
    root('/bin/sh', '-c', CHECK, sha, staged),
    root('install', '-m', mode, '-o', 'root', '-g', 'wheel', staged, `${dest}.new`),
    root('/bin/sh', '-c', `printf "%s  %s\\n" "$0" "$1" | shasum -a 256 -c - >/dev/null || { rm -f "$1"; exit 1; }`, sha, `${dest}.new`),
    ...extra(`${dest}.new`),
    root('mv', '-f', `${dest}.new`, dest),
  ];
  const keep = `${r.dir}/${r.work}`;
  // What is in the folder but the two the account writes.
  const rest = [r.dir, '-mindepth', '1', '-maxdepth', '1', '!', '-name', r.work, '!', '-name', '_diag', '-exec'];
  switch (step) {
    case 'account': {
      const a = plan.accounts.find((x) => x.login === r.user);
      const u = `/Users/${a.login}`;
      const g = `/Groups/${a.group}`;
      const uid = String(ctx.uids[a.login]);
      return [
        root('/bin/sh', '-c', GROUP_FREE, a.group),
        // A group of its own (its gid is its uid): what the group may read, no other account can.
        ...[
          ['-create', g],
          ['-create', g, 'RealName', `Pronto runner (${a.login})`],
          ['-create', g, 'PrimaryGroupID', uid],
          ['-create', g, 'Password', '*'],
          ['-create', u],
          ['-create', u, 'UserShell', '/bin/bash'],
          ['-create', u, 'RealName', `Pronto runner (${a.login})`],
          ['-create', u, 'UniqueID', uid],
          ['-create', u, 'PrimaryGroupID', uid],
          ['-create', u, 'NFSHomeDirectory', a.home],
          ['-create', u, 'IsHidden', '1'],
          // No password: no login, only a daemon or sudo -u gets in.
          ['-create', u, 'Password', '*'],
        ].map((args) => root('dscl', '.', ...args)),
        root('install', '-d', '-m', a.mode, '-o', a.login, '-g', a.group, a.home),
      ];
    }
    case 'install-as':
      // The folder is made by root, the account's while it is installed and registered (and locked after).
      return [
        root('install', '-d', '-m', '755', '-o', 'root', '-g', 'wheel', dirOf(r.dir)),
        root('install', '-d', '-m', '750', '-o', r.user, '-g', r.group, r.dir),
        root('/bin/sh', '-c', TAR, r.download.sha256, `${ctx.stage}/runner.tar.gz`, r.user, r.dir),
        // The tarball's symlinks, kept in root's folder for the lock to hold the tree to.
        root('/bin/sh', '-c', MANIFEST, r.download.sha256, `${ctx.stage}/runner.tar.gz`, manifest, r.work),
      ];
    case 'unregister-as':
      return [{ ...sh(r.dir, `${TOKEN_IN} && exec ./config.sh remove`), token: true }];
    case 'register-as':
      // The runner's own updater would rewrite its folder, which is root's: it is told not to.
      return [{ ...sh(r.dir, `${TOKEN_IN} && exec ./config.sh "$@"`, ...registerArgs(plan, name), '--disableupdate'), token: true }];
    case 'unlock':
      // Nothing of the account runs while its folder is handed back (quiesce), and what is chowned is never followed
      // through a symlink (-h); _work and _diag are not touched. The subtree goes first and the folder last: the
      // account reaches nothing by the folder before then, so it can't hard-link a root file into a tree about to be
      // chowned to it.
      return [
        ...quiesce(),
        root('find', ...rest, 'chown', '-h', '-R', `${r.user}:${r.group}`, '{}', '+'),
        root('chown', '-h', `${r.user}:${r.group}`, r.dir),
      ];
    case 'lock':
      // Root's but for the folders its jobs write, and readable by the account's group alone (the listener only
      // reads .env, .path, .credentials*, bin/; it writes _work and _diag, the account's, mode 700). Nothing of the
      // account runs (quiesce) and the folder is root's, mode 700, before anything in it is looked at; a _work or
      // _diag that is a symlink is removed; the tree must hold the tarball's symlinks and no others, no multiply-linked
      // file, a .path that is the plan's and a .env that is empty or a LANG. _work and _diag are made by root while
      // the folder is still root's 700 (MAKE), so the folder is never the account's; it is chowned last.
      return [
        ...quiesce(),
        root('chown', '-h', 'root:wheel', r.dir),
        root('chmod', '700', r.dir),
        root('/bin/sh', '-c', UNLINK, keep, `${r.dir}/_diag`),
        root('/bin/sh', '-c', CLEAN, r.dir, r.work, manifest),
        root('find', ...rest, 'chown', '-h', '-R', `root:${r.group}`, '{}', '+'),
        root('find', ...rest, 'chmod', '-R', 'g+rX,go-w,o-rwx', '{}', '+'),
        root('/bin/sh', '-c', ENVCHECK, r.dir, r.path),
        root('/bin/sh', '-c', MAKE, r.user, r.group, keep, `${r.dir}/_diag`),
        root('chmod', '750', r.dir),
        root('chown', '-h', `root:${r.group}`, r.dir),
      ];
    case 'tools':
      // gh is the one pinned tool (the setup's versions.gh), checked as staged, as installed and for its links;
      // the rest of the trusted tools are the system's.
      return [
        root('install', '-d', '-m', '755', '-o', 'root', '-g', 'wheel', dirOf(r.tools.dir), r.tools.dir),
        ...put(r.tools.gh.binary, `${ctx.stage}/gh`, `${r.tools.dir}/gh`, '755', (p) => [root('/bin/sh', '-c', LINKS, p)]),
      ];
    case 'hook':
      return [root('install', '-d', '-m', '755', '-o', 'root', '-g', 'wheel', dirOf(r.hook.path)), ...put(r.hook.sha256, `${ctx.stage}/job-started.sh`, r.hook.path, r.hook.mode)];
    case 'daemon': {
      const logs = dirOf(r.service.plist.StandardOutPath);
      return [
        root('install', '-d', '-m', '755', '-o', 'root', '-g', 'wheel', dirOf(logs)),
        root('install', '-d', '-m', '755', '-o', 'root', '-g', 'wheel', logs),
        ...put(r.service.sha256, `${ctx.stage}/plist`, r.service.path, '644'),
        bootout(),
        root('launchctl', 'bootstrap', 'system', r.service.path),
      ];
    }
    case 'remove-daemon': {
      // A runner that is the applier's own again: the daemon it was, unloaded and its plist removed.
      const plist = `/Library/LaunchDaemons/${r.service.label}.plist`;
      return [bootout(), root('rm', '-f', plist)];
    }
  }
  return [];
}

/** A word as a person types it: quoted unless it is plain. */
const quote = (a) => /^[A-Za-z0-9_./:=@%+,-]+$/.test(a) ? a : `'${a.replace(/'/g, "'\\''")}'`;

/** A command as a person types it: quoted, `sudo -n` as `sudo`, its token on stdin from `"$t"` (set by tokenHelp), its stdin from `cat`. */
export function shell(cmd) {
  const argv = cmd.argv[0] === 'sudo' && cmd.argv[1] === '-n' ? ['sudo', ...cmd.argv.slice(2)] : cmd.argv;
  const feed = cmd.token ? "printf '%s\\n' \"$t\" | " : cmd.stdin ? `cat ${quote(cmd.stdin)} | ` : '';
  return `${feed}${argv.map(quote).join(' ')}${cmd.tolerate ? ' || true' : ''}`;
}

/** What a person runs first, to hold a registration token for the commands that read it. */
export const tokenHelp = (plan, name, kind) => `t=$(gh api -X POST ${plan.host[name].api}/${kind}-token --jq .token)`;

/**
 * A host runner's registration, from what runners.ts found: its .runner file (`runner`, parsed, or
 * null), its .path (`path`) and the labels GitHub holds for it (`labels`, null when gh can't say).
 * `none`, `current` (what the plan registers), or `stale` (registered otherwise: another repository,
 * name, work folder, PATH or labels).
 */
export function registration(plan, name, found) {
  const r = plan.host[name];
  if (!found.runner) return 'none';
  const f = Object.fromEntries(Object.entries(found.runner).map(([k, v]) => [k.toLowerCase(), v]));
  const same = f.agentname === name && f.githuburl === r.url && f.workfolder === r.work && (found.path ?? '').trim() === r.path;
  const labels = found.labels === null || r.labels.every((l) => found.labels.includes(l));
  return same && labels ? 'current' : 'stale';
}

/** config.sh's arguments for a host runner, the token left out: runners.ts adds it, never a file. */
export function registerArgs(plan, name) {
  const r = plan.host[name];
  return ['--unattended', '--url', r.url, '--name', name, '--labels', r.labels.join(','), '--work', r.work, '--replace'];
}

/**
 * config.sh as a command whose registration or removal token is its stdin, never an argument (another account could
 * read an argument with ps and register a runner of the same label): read into ACTIONS_RUNNER_INPUT_TOKEN, which
 * config.sh takes as --token.
 */
export const configCommand = (args) => ['/bin/sh', '-c', `${TOKEN_IN} && exec ./config.sh "$@"`, 'sh', ...args];

/** What a person runs when gh can't fetch the registration token (no admin on the repository). */
export function registerHelp(plan, name) {
  const r = plan.host[name];
  return [
    `A registration token for ${r.url.replace('https://github.com/', '')} needs admin on it. With a gh login that has it:`,
    `cd ${quote(r.dir)} && gh api -X POST ${r.api}/registration-token --jq .token | ( ${TOKEN_IN} && ./config.sh ${registerArgs(plan, name).join(' ')} )`,
  ];
}
