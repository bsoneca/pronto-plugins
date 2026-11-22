// release-cron's lock (release-cron/cron.js lockAcquire) on an in-memory file system and a virtual clock, whose rename behaves as macOS's
// rename(2) does: onto an empty directory it replaces it, onto a directory with content it fails with ENOTEMPTY. A case names the
// state the lock is found in (`dirs`: path -> age in ms; `files`: path -> text), the pids that answer a signal (`alive`), the errors the
// kill -0 gives (`kill`: pid -> error code, else ESRCH unless the pid is in `alive`), the errors the
// system gives (`fail`: { op, path (a substring), code }) and what the other run does while this one waits (`after`: files it writes
// once `sleeps` sleeps have passed, and `during` {pid}: the pid of a run that, while this one is paused after its mkdir, replaces the lock's directory with its own); the result is the take's outcome, or the thrown message, and the lock's pid file as it ends.
import { lockAcquire, aliveFromKill } from '../../release-cron/cron.js';

const err = (code, msg) => Object.assign(new Error(`${code}: ${msg}`), { code });

export function run({ dirs = {}, files = {}, alive = [], kill = {}, fail = [], after = null, pid = 500, path = 'state/lock', options } = {}) {
  let t = 1_000_000, sleeps = 0, n = 0;
  const nodes = new Map(); let paused = after && after.during;
  for (const [p, age] of Object.entries(dirs)) nodes.set(p, { dir: true, mtime: t - age });
  for (const [p, text] of Object.entries(files)) nodes.set(p, { dir: false, text, mtime: t - 60_000 });
  const kids = (p) => [...nodes.keys()].filter((k) => k.startsWith(`${p}/`));
  const check = (op, p) => { const f = fail.find((x) => x.op === op && (!x.path || p.includes(x.path))); if (f) throw err(f.code, `${op} ${p}`); };
  const io = {
    pid, now: () => t,
    uuid: () => `u${++n}`,
    sleep: (ms) => { t += ms; sleeps++; if (after && after.files && sleeps === (after.sleeps ?? 1)) for (const [p, text] of Object.entries(after.files ?? {})) nodes.set(p, { dir: false, text, mtime: t }); },
    alive: (p) => aliveFromKill(kill[p] ?? (alive.includes(p) ? null : 'ESRCH')),
    mkdir: (p) => {
      check('mkdir', p); if (nodes.has(p)) throw err('EEXIST', p); nodes.set(p, { dir: true, mtime: t });
      // this run is paused here, after its mkdir: another run replaces the directory with its own, whole
      if (p === path && paused) { for (const k of [p, ...kids(p)]) nodes.delete(k); nodes.set(p, { dir: true, mtime: t }); nodes.set(`${p}/pid`, { dir: false, text: paused.pid, mtime: t }); paused = null; }
    },
    link: (a, b) => { check('link', a); const x = nodes.get(a); if (!x) throw err('ENOENT', a); if (nodes.has(b)) throw err('EEXIST', b); nodes.set(b, { ...x }); },
    writeFile: (p, text) => { check('writeFile', p); if (!nodes.has(p.slice(0, p.lastIndexOf('/')))) throw err('ENOENT', p); nodes.set(p, { dir: false, text, mtime: t }); },
    readFile: (p) => { check('readFile', p); const x = nodes.get(p); if (!x || x.dir) throw err(x ? 'EISDIR' : 'ENOENT', p); return x.text; },
    stat: (p) => { check('stat', p); const x = nodes.get(p); if (!x) throw err('ENOENT', p); return { isFile: !x.dir, mtimeMs: x.mtime }; },
    rename: (a, b) => {
      check('rename', a);
      const x = nodes.get(a); if (!x) throw err('ENOENT', a);
      const dst = nodes.get(b);
      if (dst && dst.dir && kids(b).length) throw err('ENOTEMPTY', b);
      if (dst && !dst.dir !== !x.dir) throw err(dst.dir ? 'EISDIR' : 'ENOTDIR', b);
      nodes.delete(b);
      for (const k of [a, ...kids(a)]) { nodes.set(b + k.slice(a.length), nodes.get(k)); nodes.delete(k); }
    },
    remove: (p) => { check('remove', p); for (const k of [p, ...kids(p)]) nodes.delete(k); },
  };
  let result;
  try { result = lockAcquire(io, path, options); } catch (e) { result = { threw: e.message }; }
  const held = nodes.get(`${path}/pid`);
  return { ...result, pid_file: held ? held.text : null, lock_kind: nodes.has(path) ? (nodes.get(path).dir ? 'dir' : 'file') : null };
}
