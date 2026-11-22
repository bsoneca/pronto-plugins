// release-cron's lock (release-cron/cron.js lockAcquire, lockRelease) on an in-memory file system with symbolic links and a virtual clock, whose
// rename behaves as macOS's rename(2) does: onto an empty directory it replaces it, onto a directory with content it fails with ENOTEMPTY, and
// symlink(2) fails EEXIST for anything at the path. A case names the state the lock is found in (`dirs`: path -> age in ms; `files`: path ->
// text; `links`: path -> target, relative to the link's folder), the pids that answer a signal (`alive`), what kill -0 gives (`kill`: pid -> error
// code, else ESRCH unless the pid is in `alive`), the errors the system gives (`fail`: { op, path (a substring), code }), and what happens
// meanwhile (`after`: `files` another run writes once `sleeps` sleeps have passed; `emptyDirFirst`: a base driver's mkdir of the lock lands just
// before this run's symlink; `inRecovery` {pid}: another run recovers the lock first and a live run of that pid holds a new one; `renameSwaps`
// text: the lock renamed away turns out to hold that pid, as when another run replaced it). The result is the outcome, or the thrown message, the
// lock's pid file (read through a link) and kind as they end, `linkedWhole` (every symlink onto the lock pointed at a directory already holding a
// pid) and `madeLockDir` (the lock itself was ever made empty, with mkdir).
import { lockAcquire, lockRelease, aliveFromKill, previewRecordStop, previewRecorded, previewRecord } from '../../release-cron/cron.js';

const err = (code, msg) => Object.assign(new Error(`${code}: ${msg}`), { code });
const dirOf = (p) => p.slice(0, p.lastIndexOf('/'));

function fs(init, fail, path) {
  const nodes = new Map();
  const st = { n: 0, linkedWhole: true, madeLockDir: false, t: 1_000_000 };
  for (const [p, age] of Object.entries(init.dirs ?? {})) nodes.set(p, { dir: true, mtime: st.t - age });
  for (const [p, text] of Object.entries(init.files ?? {})) nodes.set(p, { dir: false, text, mtime: st.t - 60_000 });
  for (const [p, target] of Object.entries(init.links ?? {})) nodes.set(p, { link: target, mtime: st.t - 60_000 });
  // resolves links in every folder component, and in the last when `last`
  const res = (p, last = true, depth = 0) => {
    if (depth > 8) throw err('ELOOP', p);
    const parts = p.split('/');
    for (let i = 1; i <= parts.length; i++) {
      if (i === parts.length && !last) break;
      const pre = parts.slice(0, i).join('/'), x = nodes.get(pre);
      if (x && x.link !== undefined) return res([`${dirOf(pre)}/${x.link}`, ...parts.slice(i)].join('/'), last, depth + 1);
    }
    return p;
  };
  const kids = (p) => [...nodes.keys()].filter((k) => k.startsWith(`${p}/`));
  const check = (op, p) => { const f = fail.find((x) => x.op === op && (!x.path || p.includes(x.path))); if (f) throw err(f.code, `${op} ${p}`); };
  const io = {
    mkdir: (p) => { check('mkdir', p); const q = res(p, false); if (nodes.has(q)) throw err('EEXIST', p); if (p === path) st.madeLockDir = true; nodes.set(q, { dir: true, mtime: st.t }); },
    writeFile: (p, text) => { check('writeFile', p); const q = res(p); if (!nodes.has(dirOf(q))) throw err('ENOENT', p); nodes.set(q, { dir: false, text, mtime: st.t }); },
    readFile: (p) => { check('readFile', p); const x = nodes.get(res(p)); if (!x || x.dir || x.link !== undefined) throw err(x ? 'EISDIR' : 'ENOENT', p); return x.text; },
    stat: (p) => { check('stat', p); const x = nodes.get(res(p)); if (!x) throw err('ENOENT', p); return { isFile: !x.dir, mtimeMs: x.mtime }; },
    lstat: (p) => { check('lstat', p); const x = nodes.get(res(p, false)); if (!x) throw err('ENOENT', p); return { isFile: !x.dir && x.link === undefined, isLink: x.link !== undefined, mtimeMs: x.mtime }; },
    readlink: (p) => { check('readlink', p); const x = nodes.get(res(p, false)); if (!x || x.link === undefined) throw err('EINVAL', p); return x.link; },
    symlink: (target, p) => {
      check('symlink', p);
      if (init.emptyDirFirst && p === path && !st.raced) { st.raced = true; nodes.set(p, { dir: true, mtime: st.t }); }
      if (nodes.has(p)) throw err('EEXIST', p);
      if (p === path && !nodes.has(`${dirOf(p)}/${target}/pid`)) st.linkedWhole = false;
      nodes.set(p, { link: target, mtime: st.t });
    },
    link: (a, b) => { check('link', a); const x = nodes.get(res(a)); if (!x) throw err('ENOENT', a); if (nodes.has(res(b, false))) throw err('EEXIST', b); nodes.set(res(b, false), { ...x }); },
    unlink: (p) => { check('unlink', p); const q = res(p, false); if (!nodes.has(q)) throw err('ENOENT', p); nodes.delete(q); },
    rename: (a, b) => {
      check('rename', a);
      const qa = res(a, false), qb = res(b, false);
      if (a === path && init.renameSwaps && b.includes('.gone.')) { const t = res(a); nodes.set(`${t}/pid`, { dir: false, text: init.renameSwaps, mtime: st.t }); }
      const x = nodes.get(qa); if (!x) throw err('ENOENT', a);
      const dst = nodes.get(qb);
      if (dst && dst.dir && kids(qb).length) throw err('ENOTEMPTY', b);
      if (dst && !dst.dir !== !x.dir) throw err(dst.dir ? 'EISDIR' : 'ENOTDIR', b);
      nodes.delete(qb);
      for (const k of [qa, ...kids(qa)]) { nodes.set(qb + k.slice(qa.length), nodes.get(k)); nodes.delete(k); }
    },
    remove: (p) => { check('remove', p); const q = res(p, false); for (const k of [q, ...kids(q)]) nodes.delete(k); },
  };
  return { nodes, io, st, res, kids };
}
const kindOf = (nodes, p) => { const x = nodes.get(p); return x ? (x.link !== undefined ? 'link' : x.dir ? 'dir' : 'file') : null; };

export function run(c = {}) {
  const { alive = [], kill = {}, fail = [], after = null, pid = 500, path = 'state/lock', options } = c;
  const f = fs({ ...c, emptyDirFirst: after && after.emptyDirFirst, renameSwaps: after && after.renameSwaps }, fail, path);
  let sleeps = 0;
  Object.assign(f.io, {
    pid, now: () => f.st.t, uuid: () => `u${++f.st.n}`,
    sleep: (ms) => { f.st.t += ms; sleeps++; if (after && after.files && sleeps === (after.sleeps ?? 1)) for (const [p, text] of Object.entries(after.files)) f.nodes.set(f.res(p), { dir: false, text, mtime: f.st.t }); },
    alive: (p) => aliveFromKill(kill[p] ?? (alive.includes(p) ? null : 'ESRCH')),
    recovering: (fn) => {
      if (after && after.inRecovery) {
        for (const k of [path, ...f.kids(path)]) f.nodes.delete(k);
        f.nodes.set(path, { dir: true, mtime: f.st.t }); f.nodes.set(`${path}/pid`, { dir: false, text: after.inRecovery.pid, mtime: f.st.t });
      }
      return fn();
    },
  });
  let result;
  try { const r = lockAcquire(f.io, path, options); result = r.got ? { got: true } : r; } catch (e) { result = { threw: e.message }; }
  let held = null;
  try { held = f.nodes.get(f.res(`${path}/pid`)); } catch { /* no lock */ }
  return { ...result, pid_file: held && !held.dir ? held.text : null, lock_kind: kindOf(f.nodes, path), linkedWhole: f.st.linkedWhole, madeLockDir: f.st.madeLockDir };
}

// lockRelease on the same file system: `files`/`dirs`/`links`/`fail` as above, `pid` this run's, `stage` the staging directory it holds the lock by.
export function release(c = {}) {
  const { fail = [], pid = 500, path = 'state/lock', stage } = c;
  const f = fs(c, fail, path);
  Object.assign(f.io, { pid, uuid: () => `u${++f.st.n}` });
  let out;
  try { out = { result: lockRelease(f.io, path, stage) }; } catch (e) { out = { threw: e.message }; }
  return { ...out, lock_kind: kindOf(f.nodes, path), staging_left: [...f.nodes.keys()].some((k) => /\.new\.[^/]*$/.test(k)) };
}

// The preview record's stop: `err` the read's error code (null when it read), `text` the content.
export const preview = (err, text) => previewRecordStop(err, text, 'state/lock.preview');

// The release preview under its record (cron.js previewRecorded) on the same file system: `existing` a record already there, `up`/`down` the exits of
// the two commands, `throwAfterUp` the run killed after `up` (the body never reaches its `down`), `fail` the system's errors. `order` is what happened
// in sequence, `recordedBeforeUp` whether the record stood when `up` started; `record` is the record's state at the end ("kept", "removed" when there
// is none) and `next` what the next run that takes the lock is told of it (previewRecordStop).
export async function previewCycle(c = {}) {
  const { existing = null, up = 0, down = 0, throwAfterUp = false, fail = [], pid = 500 } = c;
  const path = 'state/lock.preview';
  const f = fs({ dirs: { state: 0 }, files: existing === null ? {} : { [path]: existing } }, fail, 'state/lock');
  Object.assign(f.io, { pid, uuid: () => `u${++f.st.n}` });
  const order = [];
  let recordedBeforeUp = null, threw = null;
  const pv = { up: ['mise', 'run', 'up'], down: ['mise', 'run', 'down'] };
  try {
    await previewRecorded(f.io, path, previewRecord(pv, '/w/app', pid, 'at'), async () => {
      await Promise.resolve(); // `up` is a child process in the driver
      order.push('up'); recordedBeforeUp = f.nodes.has(path);
      if (throwAfterUp) throw new Error('killed');
      order.push('down');
      return { downCode: down, upCode: up };
    });
  } catch (e) { threw = e.message; }
  const rec = f.nodes.get(path);
  let next = null;
  if (rec) next = previewRecordStop(null, rec.text, path);
  return { order, recordedBeforeUp, record: rec ? 'kept' : 'removed', threw, next, stray: [...f.nodes.keys()].some((k) => k.endsWith('.tmp')) };
}
