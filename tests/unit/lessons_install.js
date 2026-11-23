// What pronto-lessons' installer cases call (tests/unit/lessons.cue, namespace lessonsinstall): lessons/install.ts run on a
// temporary pronto app, as bin/pronto-lessons runs it (the same deno, the same permissions).
const here = new URL('.', import.meta.url).pathname;
const installer = `${here}../../lessons/install.ts`;

/** A temporary app: its program's package, pronto-flags' plugin file unless `flags` is false, the raw migrations its CUE lists
 * (`raw`, as program.cue's rawMigrations does unless `list` is false) and the pgroll names its plugins use (`pgroll`, as
 * `_xMigration` constants); `files` more. */
export function app({ pkg = 'shop', flags = true, full = 0, raw = full ? Array.from({ length: full + 1 }, (_, n) => `${String(n).padStart(3, '0')}_x.sql`) : [], pgroll = [], list = true, files = {} } = {}) {
  const dir = Deno.makeTempDirSync();
  Deno.writeTextFileSync(`${dir}/program.cue`, `package ${pkg}\n${raw.length && list ? `code: state: rawMigrations: [${raw.map((n) => `{name: "${n}", src: "sql/${n}"}`).join(', ')}]\n` : ''}`);
  if (raw.length && !list) put(dir, 'spec/raw.cue', `package ${pkg}\n_x: [${raw.map((n) => `{name: "${n}", src: "sql/${n}"}`).join(', ')}]\n`);
  if (flags) Deno.writeTextFileSync(`${dir}/flags_plugin.cue`, `package ${pkg}\n`);
  if (pgroll.length) put(dir, 'billing_spec.cue', `package ${pkg}\n${pgroll.map((n, i) => `_x${i}Migration: "${n}"`).join('\n')}\n`);
  for (const [path, text] of Object.entries(files)) put(dir, path, text);
  return dir;
}

/** The installer over the app; `ok` and the text it printed (stderr when it refused). */
export async function install(dir, ...args) {
  const out = await new Deno.Command(Deno.execPath(), {
    args: ['run', '--no-config', '--allow-read', '--allow-write', '--allow-run=git', installer, dir, ...args],
    stdout: 'piped', stderr: 'piped',
  }).output();
  const text = (b) => new TextDecoder().decode(b);
  return { ok: out.success, out: text(out.stdout), err: text(out.stderr) };
}

export function put(dir, path, text) {
  Deno.mkdirSync(`${dir}/${path}`.replace(/\/[^/]+$/, ''), { recursive: true });
  Deno.writeTextFileSync(`${dir}/${path}`, text);
}

/** Every file of the app, as {path: text}. */
export function snapshot(dir) {
  const out = {};
  const walk = (rel) => {
    for (const e of Deno.readDirSync(`${dir}/${rel}`)) {
      const p = rel ? `${rel}/${e.name}` : e.name;
      if (e.isDirectory) walk(p);
      else out[p] = Deno.readTextFileSync(`${dir}/${p}`);
    }
  };
  walk('');
  return out;
}

/** The paths that differ between two snapshots (added, removed, changed). */
export function changed(before, after) {
  return [...new Set([...Object.keys(before), ...Object.keys(after)])].filter((p) => before[p] !== after[p]).sort();
}

/** The paths of a snapshot, sorted, and those that are not the app's own starting files. */
export const paths = (snap) => Object.keys(snap).sort();

/** The names of a folder's files in the order a C locale sorts them. */
export function sorted(snap, folder) {
  return Object.keys(snap).filter((p) => p.startsWith(`${folder}/`)).map((p) => p.slice(folder.length + 1)).sort();
}

export const text = (snap, path) => snap[path] ?? null;
/** One name of a raw migration's list, as lessons_plugin.cue holds it. */
export const names = (snap) => ({ spec: /spec: "([^"]+)"/.exec(snap['lessons_spec.cue'])?.[1], fns: /fns: "([^"]+)"/.exec(snap['lessons_spec.cue'])?.[1], pgroll: /^_lessonsMigration: "([^"]+)"/m.exec(snap['lessons_spec.cue'])?.[1] });
export const first = (snap, path) => (snap[path] ?? '').split('\n')[0];
export const has = (snap, path, part) => (snap[path] ?? '').includes(part);

/** The page module's header names the commit, or says it is the host's when there is no checkout. */
export const stamp = (snap, path) => /^\/\/ Written by pronto-lessons, generated from bsoneca\/pronto-plugins@[0-9a-f]{12} \(lessons\/app\/lessons\.js\); regenerated, do not edit\.$/m.test((snap[path] ?? '').split('\n')[0]);

export function remove(dir) {
  Deno.removeSync(dir, { recursive: true });
}
