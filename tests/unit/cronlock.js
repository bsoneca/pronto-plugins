// release-cron's lock (release-cron/cron.js lockAcquire, lockRelease) on an in-memory file system and a virtual clock, whose rename behaves as
// macOS's rename(2) does: onto an empty directory it replaces it, onto a directory with content it fails with ENOTEMPTY. A case names the
// state the lock is found in (`dirs`: path -> age in ms; `files`: path -> text), the pids that answer a signal (`alive`), what kill -0 gives
// (`kill`: pid -> error code, else ESRCH unless the pid is in `alive`), the errors the system gives (`fail`: { op, path (a substring), code }),
// and what happens meanwhile (`after`: `files` another run writes once `sleeps` sleeps have passed; `inRecovery` {pid}: another run recovers
// the lock first and a live run of that pid holds a new one; `renameSwaps` text: the lock renamed away turns out to hold that pid, as when
// another run replaced it). The result is the outcome, or the thrown message, the lock's pid file and kind as they end, `renamedWhole` (every
// rename onto the lock came from a directory already holding a pid) and `madeLockDir` (the lock itself was ever made empty, with mkdir).
import { lockAcquire, lockRelease, aliveFromKill } from '../../release-cron/cron.js';

const err = (code, msg) => Object.assign(new Error(`${code}: ${msg}`), { code });

export function run({ dirs = {}, files = {}, alive = [], kill = {}, fail = [], after = null, pid = 500, path = 'state/lock', options } = {}) {
  let t = 1_000_000, sleeps = 0, n = 0, renamedWhole = true, madeLockDir = false;
  const nodes = new Map();
  for (const [p, age] of Object.entries(dirs)) nodes.set(p, { dir: true, mtime: t - age });
  for (const [p, text] of Object.entries(files)) nodes.set(p, { dir: false, text, mtime: t - 60_000 });
  const kids = (p) => [...nodes.keys()].filter((k) => k.startsWith(`${p}/`));
  const check = (op, p) => { const f = fail.find((x) => x.op === op && (!x.path || p.includes(x.path))); if (f) throw err(f.code, `${op} ${p}`); };
  const io = {
    pid, now: () => t,
    uuid: () => `u${++n}`,
    sleep: (ms) => { t += ms; sleeps++; if (after && after.files && sleeps === (after.sleeps ?? 1)) for (const [p, text] of Object.entries(after.files ?? {})) nodes.set(p, { dir: false, text, mtime: t }); },
    alive: (p) => aliveFromKill(kill[p] ?? (alive.includes(p) ? null : 'ESRCH')),
    mkdir: (p) => { check('mkdir', p); if (nodes.has(p)) throw err('EEXIST', p); if (p === path) madeLockDir = true; nodes.set(p, { dir: true, mtime: t }); },
    recovering: (f) => {
      if (after && after.inRecovery) { for (const k of [path, ...kids(path)]) nodes.delete(k); nodes.set(path, { dir: true, mtime: t }); nodes.set(`${path}/pid`, { dir: false, text: after.inRecovery.pid, mtime: t }); }
      return f();
    },
    writeFile: (p, text) => { check('writeFile', p); if (!nodes.has(p.slice(0, p.lastIndexOf('/')))) throw err('ENOENT', p); nodes.set(p, { dir: false, text, mtime: t }); },
    readFile: (p) => { check('readFile', p); const x = nodes.get(p); if (!x || x.dir) throw err(x ? 'EISDIR' : 'ENOENT', p); return x.text; },
    stat: (p) => { check('stat', p); const x = nodes.get(p); if (!x) throw err('ENOENT', p); return { isFile: !x.dir, mtimeMs: x.mtime }; },
    rename: (a, b) => {
      check('rename', a);
      if (b === path && !nodes.has(`${a}/pid`)) renamedWhole = false;
      if (a === path && after && after.renameSwaps && b.includes('.gone.')) nodes.set(`${a}/pid`, { dir: false, text: after.renameSwaps, mtime: t });
      const x = nodes.get(a); if (!x) throw err('ENOENT', a);
      const dst = nodes.get(b);
      if (dst && dst.dir && kids(b).length) throw err('ENOTEMPTY', b);
      if (dst && !dst.dir !== !x.dir) throw err(dst.dir ? 'EISDIR' : 'ENOTDIR', b);
      nodes.delete(b);
      for (const k of [a, ...kids(a)]) { nodes.set(b + k.slice(a.length), nodes.get(k)); nodes.delete(k); }
    },
    remove: (p) => { check('remove', p); for (const k of [p, ...kids(p)]) nodes.delete(k); },
  };
  const run_ = () => lockAcquire(io, path, options);
  let result;
  try { result = run_(); } catch (e) { result = { threw: e.message }; }
  const held = nodes.get(`${path}/pid`);
  return { ...result, pid_file: held ? held.text : null, lock_kind: nodes.has(path) ? (nodes.get(path).dir ? 'dir' : 'file') : null, renamedWhole, madeLockDir };
}

// lockRelease on the same file system: `files`/`dirs`/`fail` as above, `pid` this run's.
export function release({ dirs = {}, files = {}, fail = [], pid = 500, path = 'state/lock' } = {}) {
  const nodes = new Map(); let n = 0;
  for (const p of Object.keys(dirs)) nodes.set(p, { dir: true });
  for (const [p, text] of Object.entries(files)) nodes.set(p, { dir: false, text });
  const kids = (p) => [...nodes.keys()].filter((k) => k.startsWith(`${p}/`));
  const check = (op, p) => { const f = fail.find((x) => x.op === op && (!x.path || p.includes(x.path))); if (f) throw err(f.code, `${op} ${p}`); };
  const io = {
    pid, uuid: () => `u${++n}`,
    readFile: (p) => { check('readFile', p); const x = nodes.get(p); if (!x || x.dir) throw err('ENOENT', p); return x.text; },
    rename: (a, b) => { check('rename', a); if (!nodes.has(a)) throw err('ENOENT', a); for (const k of [a, ...kids(a)]) { nodes.set(b + k.slice(a.length), nodes.get(k)); nodes.delete(k); } },
    remove: (p) => { check('remove', p); for (const k of [p, ...kids(p)]) nodes.delete(k); },
  };
  let out;
  try { out = { result: lockRelease(io, path) }; } catch (e) { out = { threw: e.message }; }
  return { ...out, lock_kind: nodes.has(path) ? 'dir' : null };
}
