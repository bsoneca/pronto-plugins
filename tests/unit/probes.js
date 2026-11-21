// Small measures the cases read a value through (tests/unit/*.cue).
import { createHash } from 'node:crypto';

/** Whether a text holds a part. */
export const includes = (text, part) => String(text ?? '').includes(part);
/** Whether a text holds each part, as a list of whether it does. */
export const holdsEach = (text, parts) => parts.map((p) => String(text ?? '').includes(p));
/** The elements of a list from an index on. */
export const from = (list, i) => list.slice(i);
/** The last element of a list. */
export const last = (list) => list.at(-1);
/** Whether every element of a list is the value. */
export const every = (list, v) => list.every((x) => x === v);
/** A text's length. */
export const length = (text) => String(text ?? '').length;
/** Whether two values are the same. */
export const same = (a, b) => JSON.stringify(a) === JSON.stringify(b);
/** A text with a pattern replaced. */
export const replaced = (text, pattern, by) => String(text).replace(new RegExp(pattern, 'm'), by);
/** A text repeated. */
export const repeat = (text, n) => String(text).repeat(n);
/** How many distinct values a list holds. */
export const distinct = (list) => new Set(list.map((x) => JSON.stringify(x))).size;
/** How many <dict> entries a launchd plist holds, the job's own and its environment's. */
export const dictEntries = (plist) => (plist.match(/<dict>/g) ?? []).length;
/** Whether two values differ, as JSON. */
export const differs = (a, b) => JSON.stringify(a) !== JSON.stringify(b);
/** A prod-watch run's groups as what the noise cases check: how many and which rule, in the order first seen. */
export const verdicts = (groups) => Object.values(groups).sort((a, b) => (a.first < b.first ? -1 : a.first > b.first ? 1 : 0)).map((g) => ({ count: g.count, noise: g.noise }));
/** Whether none of an object's keys is any of the names. */
export const lacksKeys = (obj, names) => names.every((n) => !(n in obj));
/** bash's verdict on a script's syntax (`bash -n`): its exit code. */
export const bashSyntax = (script) => {
  const dir = Deno.makeTempDirSync();
  try {
    Deno.writeTextFileSync(`${dir}/s.sh`, script);
    return new Deno.Command('bash', { args: ['-n', `${dir}/s.sh`], stdout: 'null', stderr: 'null' }).outputSync().code;
  } finally {
    Deno.removeSync(dir, { recursive: true });
  }
};
/**
 * A generated job-started hook run as the runner runs one (`bash -e -o pipefail`) with only the
 * environment it is given: its exit code and what it said. Options: `user`, the account its `want=`
 * line names ("@me" for the one running it, absent to leave the script as generated); `homeMode`, the
 * mode of the $HOME it sees (a fresh folder); `env`; `bin`, scripts (their bodies) on its PATH ahead of
 * /usr/bin:/bin; `files`, files made first (paths under its scratch folder, `home` being $HOME); and
 * `sub`, text of the script replaced by other (@tmp the scratch folder, @uid the user's id, @group one of
 * their groups): how a case points the script's paths at what it made.
 */
export const runHook = (script, { user, env = {}, homeMode = 0o700, bin = {}, files = {}, sub = {} } = {}) => {
  const dir = Deno.makeTempDirSync();
  const out = (c, args) => new TextDecoder().decode(new Deno.Command(c, { args, stdout: 'piped' }).outputSync().stdout).trim();
  try {
    const me = out('id', ['-un']);
    let text = user === undefined ? script : script.replace(/^want='[^']*'$/m, `want='${user === '@me' ? me : user}'`);
    for (const [from, to] of Object.entries(sub)) text = text.replaceAll(from, to.replaceAll('@tmp', dir).replaceAll('@uid', out('id', ['-u'])).replaceAll('@group', out('id', ['-Gn']).split(/\s+/)[0]));
    Deno.mkdirSync(`${dir}/home`);
    Deno.mkdirSync(`${dir}/bin`);
    for (const [name, body] of Object.entries(bin)) {
      Deno.writeTextFileSync(`${dir}/bin/${name}`, `#!/bin/sh\n${body}\n`);
      Deno.chmodSync(`${dir}/bin/${name}`, 0o755);
    }
    for (const [path, body] of Object.entries(files)) {
      Deno.mkdirSync(`${dir}/${path}`.replace(/\/[^/]*$/, ''), { recursive: true });
      Deno.writeTextFileSync(`${dir}/${path}`, body);
    }
    Deno.chmodSync(`${dir}/home`, homeMode);
    Deno.writeTextFileSync(`${dir}/hook.sh`, text);
    const o = new Deno.Command('bash', { args: ['--noprofile', '--norc', '-e', '-o', 'pipefail', `${dir}/hook.sh`], clearEnv: true, env: { PATH: `${dir}/bin:/usr/bin:/bin`, HOME: `${dir}/home`, ...env }, stdout: 'null', stderr: 'piped' }).outputSync();
    return { code: o.code, said: new TextDecoder().decode(o.stderr).trim() };
  } finally {
    Deno.removeSync(dir, { recursive: true });
  }
};
/**
 * A check command of a staged file (plan.js's, run without sudo) on content written to a scratch file in
 * the staged file's place: its exit code, 0 only when the content is the one whose sha256 the plan renders.
 */
export const verifies = (argv, content) => {
  const dir = Deno.makeTempDirSync();
  try {
    Deno.writeTextFileSync(`${dir}/staged`, content);
    const args = argv.slice(argv[0] === 'sudo' ? 2 : 0).map((a) => (a.startsWith('/s/') ? `${dir}/staged` : a));
    return new Deno.Command(args[0], { args: args.slice(1), stdout: 'null', stderr: 'null' }).outputSync().code;
  } finally {
    Deno.removeSync(dir, { recursive: true });
  }
};
/**
 * A command of plan.js's (run without sudo) with files and scripts made first, as runHook does, and some of
 * its arguments replaced (an argument equal to a key, @tmp being the scratch folder; `fifos` named pipes, `links` symlinks and `hardlinks` hard links made there, `acls` paths given an ACL entry): its exit code, what it said, and whether each replaced path is still there (a symlink counts as itself); `then`, more commands run after it in the same folder, each answering `{code, said}` in `then`.
 *
 * A command that needs macOS (mtree, stat -f, chmod -N, chflags, ls -le, an ACL: the runners' scripts are for a Mac's
 * LaunchDaemons) is run for real on macOS. Off it, as machine.js's owner probe does, the cases check macOS's behaviour
 * and the probe answers as macOS did: each command's script must still parse (sh -n), and the answer is the one
 * runners_macos.json recorded (RECORD_MACOS=1 on a Mac writes it; a Mac that finds an answer stale or missing fails).
 */
const MAC_ONLY = /mtree|stat -f|chmod -[hN]|chmod \+a|chflags|ls -l[deO]+|\.mtree/;
const macTable = new URL('./runners_macos.json', import.meta.url);
const darwin = Deno.build.os === 'darwin';
const asMac = (r) => JSON.parse(JSON.stringify(r).replace(/\/(private\/)?var\/folders\/[^/\s"\\]+\/[^/\s"\\]+\/T\/[^/\s"\\]+/g, '@tmp'));
const recorded = () => { try { return JSON.parse(Deno.readTextFileSync(macTable)); } catch { return {}; } };
const scriptsOf = (cmd) => cmd.flatMap((a, i) => (cmd[i - 1] === '-c' && /sh$/.test(cmd[i - 2] ?? '') ? [a] : []));
export const runCommand = (argv, opts = {}) => {
  const { bin = {}, files = {}, fifos = [], links = {}, hardlinks = {}, acls = [], then = [], replace = {} } = opts;
  const needsMac = acls.length > 0 || MAC_ONLY.test(JSON.stringify([argv, then]));
  const key = createHash('sha256').update(JSON.stringify([argv, opts])).digest('hex').slice(0, 24);
  if (needsMac && !darwin) {
    for (const script of [argv, ...then].flatMap(scriptsOf)) {
      if (!new Deno.Command('/bin/sh', { args: ['-n', '-c', script], stdout: 'null', stderr: 'piped' }).outputSync().success) throw new Error(`a script that does not parse: ${script.slice(0, 80)}`);
    }
    const known = recorded()[key];
    if (!known) throw new Error(`no macOS answer recorded for this command (${key}): run the runners suite on a Mac with RECORD_MACOS=1`);
    return known;
  }
  const dir = Deno.makeTempDirSync();
  try {
    Deno.mkdirSync(`${dir}/bin`);
    for (const [name, body] of Object.entries(bin)) {
      Deno.writeTextFileSync(`${dir}/bin/${name}`, `#!/bin/sh\n${body}\n`);
      Deno.chmodSync(`${dir}/bin/${name}`, 0o755);
    }
    for (const [path, body] of Object.entries(files)) {
      Deno.mkdirSync(`${dir}/${path}`.replace(/\/[^/]*$/, ''), { recursive: true });
      Deno.writeTextFileSync(`${dir}/${path}`, body);
    }
    for (const path of fifos) {
      Deno.mkdirSync(`${dir}/${path}`.replace(/\/[^/]*$/, ''), { recursive: true });
      if (!new Deno.Command('/usr/bin/mkfifo', { args: [`${dir}/${path}`] }).outputSync().success) throw new Error(`mkfifo ${path}`);
    }
    for (const [path, target] of Object.entries(hardlinks)) Deno.linkSync(`${dir}/${target}`, `${dir}/${path}`);
    for (const [path, target] of Object.entries(links)) {
      Deno.mkdirSync(`${dir}/${path}`.replace(/\/[^/]*$/, ''), { recursive: true });
      Deno.symlinkSync(target, `${dir}/${path}`);
    }
    for (const path of acls) {
      if (!new Deno.Command('/bin/chmod', { args: ['+a', 'everyone allow read', `${dir}/${path}`] }).outputSync().success) throw new Error(`chmod +a ${path}`);
    }
    const to = (v) => v.replaceAll('@tmp', dir);
    const one = (cmd) => {
      const args = cmd.slice(cmd[0] === 'sudo' ? 2 : 0).map((a) => (a in replace ? to(replace[a]) : a));
      const o = new Deno.Command(args[0], { args: args.slice(1), clearEnv: true, env: { PATH: `${dir}/bin:/usr/bin:/bin` }, stdout: 'null', stderr: 'piped' }).outputSync();
      return { code: o.code, said: new TextDecoder().decode(o.stderr).trim() };
    };
    const first = one(argv);
    const after = then.map(one);
    const kept = Object.values(replace).map((v) => { try { Deno.lstatSync(to(v)); return true; } catch { return false; } });
    const got = { ...first, kept, then: after };
    if (needsMac && darwin) {
      const answer = asMac(JSON.parse(JSON.stringify(got).replaceAll(dir, '@tmp')));
      if (Deno.env.get('RECORD_MACOS')) {
        const table = recorded();
        table[key] = answer;
        Deno.writeTextFileSync(macTable, JSON.stringify(Object.fromEntries(Object.entries(table).sort()), null, 1) + '\n');
      } else {
        const known = recorded()[key];
        if (JSON.stringify(known) !== JSON.stringify(answer)) throw new Error(`the macOS answer recorded for this command (${key}) is stale or missing: run the runners suite on a Mac with RECORD_MACOS=1`);
      }
      return got;
    }
    return got;
  } finally {
    Deno.removeSync(dir, { recursive: true });
  }
};
