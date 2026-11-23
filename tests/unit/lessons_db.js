// What the lessons database cases call (tests/unit/lessons.cue, namespace lessonsdb): pronto-lessons' plugin
// (lessons/app/lessons_plugin.cue) and functions (lessons/app/lessons.sql) on PGlite, over the fixture course
// (fixtures/lessons_course.cue) emitted into the package as an install would leave it. The app's side is stood in for as
// an app's migrations would: roles, auth_uid(), the progress table its entity makes, pronto-flags' flag_on_strict
// reading a table the cases fill, and the three hooks over a wallet and a plan per account, each call recorded.
// cue is the one on PATH, or CUE.
import { PGlite } from 'npm:@electric-sql/pglite@0.3.7';
import { createLesson } from '../../lessons/app/lessons.js';
import { adapter, fakeServer } from './lessons_toy.js';

const here = new URL('.', import.meta.url).pathname;
const root = `${here}../../`;

/** The accounts the cases play as, by name: a plan each (price 0 premium, 5 plus, 10 free, none banned) and gold. */
export const ACCOUNTS = {
  PAID: '0c0c0c0c-0000-4000-8000-00000000000a',
  PLUS: '0c0c0c0c-0000-4000-8000-00000000000b',
  FREE: '0c0c0c0c-0000-4000-8000-00000000000c',
  POOR: '0c0c0c0c-0000-4000-8000-00000000000d',
  BANNED: '0c0c0c0c-0000-4000-8000-00000000000e',
  OTHER: '0c0c0c0c-0000-4000-8000-00000000000f',
};
const PLANS = { PAID: 0, PLUS: 5, FREE: 10, POOR: 10, BANNED: null, OTHER: 10 };
const GOLD = { PAID: 0, PLUS: 7, FREE: 100, POOR: 3, BANNED: 100, OTHER: 100 };
const nameOf = (uuid) => Object.keys(ACCOUNTS).find((k) => ACCOUNTS[k] === uuid) ?? uuid;
const uuidOf = (who) => ACCOUNTS[who] ?? who;

const cue = (args, cwd) => {
  const r = new Deno.Command(Deno.env.get('CUE') ?? 'cue', { args, cwd, stdout: 'piped', stderr: 'piped' }).outputSync();
  if (!r.success) throw new Error(new TextDecoder().decode(r.stderr).trim());
  return new TextDecoder().decode(r.stdout);
};

/** The plugin as an install leaves it, in a package of its own with the schema and the fixture course (or `course`'s
 * text instead): the folder. The fixture is `package lessons`, so every file is. */
function pkg(course, extra) {
  const dir = Deno.makeTempDirSync({ prefix: 'lessons-app-' });
  Deno.mkdirSync(`${dir}/cue.mod`);
  Deno.copyFileSync(`${root}cue.mod/module.cue`, `${dir}/cue.mod/module.cue`);
  Deno.copyFileSync(`${root}lessons/schema.cue`, `${dir}/schema.cue`);
  for (const f of ['lessons_plugin.cue', 'lessons_spec.cue']) Deno.writeTextFileSync(`${dir}/${f}`, Deno.readTextFileSync(`${root}lessons/app/${f}`).replaceAll('__PACKAGE__', 'lessons'));
  Deno.writeTextFileSync(`${dir}/lessons_course.cue`, course ?? Deno.readTextFileSync(`${here}fixtures/lessons_course.cue`));
  if (extra) Deno.writeTextFileSync(`${dir}/lessons_course2.cue`, extra);
  return dir;
}

let built;
/** What the plugin makes of the fixture course: the migration's SQL, the emitted files and the table's fields. */
function make() {
  if (!built) {
    const dir = pkg();
    try {
      built = JSON.parse(cue(['export', '.', '-e', '{up: _lessonsUp, out: _lessonsOut, fields: code.state.entities.LessonProgress.fields}', '--out', 'json'], dir));
    } finally {
      Deno.removeSync(dir, { recursive: true });
    }
  }
  return built;
}

/** Whether `text` is what the emitter makes of an app with no courses (the SQL the installer writes once, so a first generate finds it). */
export function emptySpecSql(text) {
  const dir = pkg('package lessons\n');
  try {
    return JSON.parse(cue(['export', '.', '-e', '_lessonsOut.sql', '--out', 'json'], dir)) === text;
  } finally {
    Deno.removeSync(dir, { recursive: true });
  }
}

/** The files `lessons write` writes: sql, js and messages (a text per locale), and the courses' ids. */
export const emit = () => make().out;

const TYPES = { text: 'text', int64: 'bigint', bool: 'boolean', timestamp: 'timestamptz', uuid: 'uuid' };

/** The progress table as the entity's fields make it: owned by its account alone (RLS), every grant given to the
 * roles, so that only the plugin's trigger stands between a session and a write. */
function table() {
  const cols = make().fields.map((f) => `${f.name} ${TYPES[f.type]}${f.pk ? ' PRIMARY KEY' : ''}${f.default ? ` DEFAULT public.${f.default}` : ''}`);
  return `CREATE TABLE public.lesson_progress (${cols.join(', ')});
    ALTER TABLE public.lesson_progress ENABLE ROW LEVEL SECURITY;
    CREATE POLICY own ON public.lesson_progress TO app_user USING (owner_id = public.auth_uid()) WITH CHECK (owner_id = public.auth_uid());
    CREATE ROLE service NOLOGIN BYPASSRLS;
    GRANT SELECT, INSERT, UPDATE, DELETE ON public.lesson_progress TO app_user, anon, service;`;
}

const BASE = `
CREATE ROLE anon NOLOGIN; CREATE ROLE app_user NOLOGIN;
CREATE FUNCTION public.auth_uid() RETURNS uuid LANGUAGE sql STABLE AS $$ SELECT nullif(current_setting('request.jwt.claims', true)::json->>'sub', '')::uuid $$;
CREATE SCHEMA test;
CREATE TABLE test.flags (flag text NOT NULL, player uuid);
CREATE TABLE test.plan (account uuid PRIMARY KEY, price int);
CREATE TABLE test.wallet (account uuid PRIMARY KEY, gold int NOT NULL);
CREATE TABLE test.calls (n serial PRIMARY KEY, kind text NOT NULL, account uuid NOT NULL, entry_key text NOT NULL, sum int NOT NULL);
CREATE SCHEMA pronto_flags;
CREATE FUNCTION pronto_flags.flag_on_strict(flag text, player uuid DEFAULT NULL) RETURNS boolean LANGUAGE sql STABLE AS $$
  SELECT EXISTS (SELECT 1 FROM test.flags f WHERE f.flag = flag_on_strict.flag AND (f.player IS NULL OR f.player = flag_on_strict.player)) $$;
`;

// The app's hooks as its migration defines them: dropped and created, then revoked again (a DROP and a CREATE leave
// the default EXECUTE for PUBLIC). The price is the account's plan's, a charge is refused when the wallet is short.
const HOOK_PRICE = `
CREATE SCHEMA IF NOT EXISTS lessons_app;
REVOKE ALL ON SCHEMA lessons_app FROM PUBLIC;
DROP FUNCTION IF EXISTS lessons_app.price(uuid);
CREATE FUNCTION lessons_app.price(who uuid) RETURNS int LANGUAGE sql STABLE AS $h$ SELECT p.price FROM test.plan p WHERE p.account = who $h$;
REVOKE ALL ON FUNCTION lessons_app.price(uuid) FROM PUBLIC;
`;
const HOOKS = HOOK_PRICE + `
DROP FUNCTION IF EXISTS lessons_app.pay(uuid, text, int);
CREATE FUNCTION lessons_app.pay(who uuid, entry text, amount int) RETURNS void LANGUAGE plpgsql AS $h$
BEGIN
  IF coalesce((SELECT w.gold FROM test.wallet w WHERE w.account = who), 0) < amount THEN
    RAISE EXCEPTION 'short of gold' USING ERRCODE = 'check_violation';
  END IF;
  UPDATE test.wallet w SET gold = w.gold - amount WHERE w.account = who;
  INSERT INTO test.calls (kind, account, entry_key, sum) VALUES ('pay', who, entry, amount);
END $h$;
DROP FUNCTION IF EXISTS lessons_app.reward(uuid, text, int);
CREATE FUNCTION lessons_app.reward(who uuid, entry text, amount int) RETURNS int LANGUAGE plpgsql AS $h$
BEGIN
  UPDATE test.wallet w SET gold = w.gold + amount WHERE w.account = who;
  INSERT INTO test.calls (kind, account, entry_key, sum) VALUES ('reward', who, entry, amount);
  RETURN amount;
END $h$;
REVOKE ALL ON FUNCTION lessons_app.pay(uuid, text, int) FROM PUBLIC;
REVOKE ALL ON FUNCTION lessons_app.reward(uuid, text, int) FROM PUBLIC;
`;

const functions = () => Deno.readTextFileSync(`${root}lessons/app/lessons.sql`);

/**
 * A live upgrade's window: pronto's schema job has made the progress table with its blanket grant and the owner's policy,
 * the plugin's pgroll migration has not run (no trigger, no lessons schema), and the raw migrations run: the courses' spec,
 * then the functions. The pgroll migration runs after only when `late`.
 */
export async function windowDb({ late = false } = {}) {
  const pg = new PGlite();
  await pg.exec(BASE + table());
  for (const [who, price] of Object.entries(PLANS)) {
    await pg.query('INSERT INTO test.plan VALUES ($1, $2)', [ACCOUNTS[who], price]);
    await pg.query('INSERT INTO test.wallet VALUES ($1, $2)', [ACCOUNTS[who], GOLD[who]]);
  }
  await pg.exec("INSERT INTO test.flags (flag) VALUES ('toy')");
  await pg.exec(HOOKS);
  await pg.exec(make().out.sql);
  await pg.exec(functions());
  if (late) await pg.exec(make().up);
  return pg;
}

/** The raw migrations alone again (the courses' spec, then the functions), as a release replays them before pgroll runs. */
export async function rerun(pg) {
  await pg.exec(make().out.sql);
  await pg.exec(functions());
  return 'ok';
}

/** The progress table's session-role write privileges and whether its trigger exists: "<n> privileges, trigger <bool>". */
export async function guarded(pg) {
  const r = (await pg.query(`SELECT (SELECT count(*)::int FROM information_schema.role_table_grants g WHERE g.table_name = 'lesson_progress' AND g.grantee IN ('app_user', 'anon', 'service') AND g.privilege_type IN ('INSERT', 'UPDATE', 'DELETE', 'TRUNCATE')) AS n,
    EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'lesson_progress_read_only' AND tgrelid = 'public.lesson_progress'::regclass) AS t`)).rows[0];
  return `${r.n} privileges, trigger ${r.t}`;
}

/** The plugin's three SQL files in a release's order, over what is there. */
async function release(pg) {
  await pg.exec(make().up);
  await pg.exec(make().out.sql);
  await pg.exec(functions());
}

/**
 * A fresh database: the app's side, the plugin's migration, the course's spec, the functions, and the same again (a
 * release replays them). `hooks: false` leaves the plugin's stubs where the app's hooks would be, `hooks: 'price'` defines only
 * the price (pay and reward stay stubs); `flagged: false` leaves
 * the course's flag off for everyone; `hooksFirst` runs the app's hook migration before the plugin's.
 */
export async function db({ hooks = true, flagged = true, hooksFirst = false } = {}) {
  const pg = new PGlite();
  await pg.exec(BASE + table());
  for (const [who, price] of Object.entries(PLANS)) {
    await pg.query('INSERT INTO test.plan VALUES ($1, $2)', [ACCOUNTS[who], price]);
    await pg.query('INSERT INTO test.wallet VALUES ($1, $2)', [ACCOUNTS[who], GOLD[who]]);
  }
  if (flagged) await pg.exec("INSERT INTO test.flags (flag) VALUES ('toy')");
  const app = hooks === 'price' ? HOOK_PRICE : HOOKS;
  if (hooks && hooksFirst) await pg.exec(app);
  await release(pg);
  if (hooks && !hooksFirst) await pg.exec(app);
  await release(pg);
  return pg;
}

/** The plugin's three files run again over the database, as the next release does. */
export async function replay(pg) {
  await release(pg);
  return 'replayed';
}

/** The course's flag turned on for the account only (`who` null: for everyone, off with `flagsOff`). */
export async function flag(pg, who) {
  await pg.query("INSERT INTO test.flags (flag, player) VALUES ('toy', $1)", [who ? uuidOf(who) : null]);
  return 'on';
}

/** Every flag off. */
export async function flagsOff(pg) {
  await pg.exec('DELETE FROM test.flags');
  return 'off';
}

const failure = (e) => `${e.code ?? '?'}: ${e.message}`;

/** `sql` as the account (SET ROLE app_user with its claims; `guest`: a guest's, `claims` more claims; 'anon': the anonymous role;
 * 'service': a service role, which writes tables as pronto's does): the rows,
 * or {refused: "<SQLSTATE>: <message>"} for what the database refused, which leaves no trace (its own transaction). */
export async function as(pg, who, sql, params = [], { guest = false, claims: more = {} } = {}) {
  try {
    return { rows: await pg.transaction(async (tx) => {
      await tx.exec(who === 'anon' ? 'SET LOCAL ROLE anon' : who === 'service' ? 'SET LOCAL ROLE service' : 'SET LOCAL ROLE app_user');
      const claims = who === 'anon' || who === 'service' ? { role: who } : { sub: uuidOf(who), role: 'app_user', ...(guest ? { guest: true } : {}), ...more };
      await tx.query("SELECT set_config('request.jwt.claims', $1, true)", [JSON.stringify(claims)]);
      return (await tx.query(sql, params)).rows;
    }) };
  } catch (e) {
    return { refused: failure(e) };
  }
}

const ARGS = { start: 2, move: 4, hint: 3 };

/** A lesson function as the account: {state}, or {refused}. `args` are the function's, in its order. */
export async function call(pg, who, fn, args, opts) {
  if (!(fn in ARGS)) throw new Error(`no function lesson_${fn}`);
  const r = await as(pg, who, `SELECT public.lesson_${fn}(${args.map((_, i) => `$${i + 1}`).join(', ')}) AS state`, args, opts);
  return r.refused ? r : { state: r.rows[0].state };
}

/** The hooks' calls so far, as the app recorded them: "<pay|reward> <account> <entry> <amount>". */
export async function calls(pg) {
  return (await pg.query('SELECT kind, account, entry_key, sum FROM test.calls ORDER BY n')).rows.map((r) => `${r.kind} ${nameOf(r.account)} ${r.entry_key} ${r.sum}`);
}

/** The ledger as it stands: "<account> <entry> <kind> <amount>", by entry. */
export async function ledger(pg) {
  return (await pg.query('SELECT owner, entry, kind, amount FROM lessons.paid ORDER BY owner, entry')).rows.map((r) => `${nameOf(r.owner)} ${r.entry} ${r.kind} ${r.amount}`);
}

/** The account's gold. */
export async function wallet(pg, who) {
  return (await pg.query('SELECT gold FROM test.wallet WHERE account = $1', [uuidOf(who)])).rows[0].gold;
}

/** The progress rows there are (read as the database's owner), as {account, chapter, step}. */
export async function rows(pg) {
  return (await pg.query('SELECT owner_id, chapter, step FROM public.lesson_progress ORDER BY owner_id, chapter')).rows.map((r) => ({ account: nameOf(r.owner_id), chapter: r.chapter, step: Number(r.step) }));
}

const sorted = (v) => (Array.isArray(v) ? v.map(sorted) : v && typeof v === 'object' ? Object.fromEntries(Object.keys(v).sort().map((k) => [k, sorted(v[k])])) : v);

/** The database's spec of the courses (read as its owner), its keys in order (jsonb has its own). */
export async function spec(pg) {
  return sorted((await pg.query('SELECT lessons.spec() AS spec')).rows[0].spec);
}

/** SQL run as the database's owner, the rows. */
export async function owner(pg, sql) {
  return (await pg.query(sql)).rows;
}

/** The emitted page's courses, loaded as the page does. */
async function page() {
  const js = emit().js;
  return (await import(`data:text/javascript;base64,${btoa(String.fromCharCode(...new TextEncoder().encode(js)))}`)).courses;
}

const counters = (s) => ({ step: Number(s.step), wrongs: Number(s.wrongs), step_wrongs: Number(s.step_wrongs), pool_said: Number(s.pool_said) });

/** The fixture's chapter `id` of the emitted page, with its part and course. */
async function chapterOf(id) {
  const course = (await page()).toy;
  for (const part of course.parts) for (const chapter of part.chapters) if (chapter.id === id) return { course, part, chapter };
  throw new Error(`no chapter ${id}`);
}

/** The chapters of the part before `two` finished as `who`, so that it is open. */
async function unlock(pg, who) {
  for (const [chapter, plies] of [['one', [[0, 'a1'], [2, 'a2'], [4, 'a3']]], ['one_b', [[0, 'a1'], [2, 'a2']]]]) {
    await call(pg, who, 'start', ['toy', chapter]);
    for (const [ply, token] of plies) await call(pg, who, 'move', ['toy', chapter, ply, token]);
  }
}

/** The database as the page's server: `move(step, token)` is lesson_move as `who`, and `last` the row it answered last. */
function dbServer(pg, who, chapterId) {
  const s = {
    last: undefined,
    async move(step, token) {
      const r = await call(pg, who, 'move', ['toy', chapterId, step, token]);
      if (r.refused) throw new Error(r.refused);
      s.last = r.state;
      return r.state;
    },
  };
  return s;
}

/**
 * The same gestures through the page's lesson (lessons.js, on the emitted courses and the toy adapter, asking the database's
 * lesson_move as `who`) on the chapter `chapter` (`two`, which the player moves from ply 1, after the first part is done for
 * them): after each, the page's counters and board against the row the database answered. {n, differ} where differ lists the
 * gestures after which they were not equal: the counters, or a board other than the plies the row says were played.
 */
export async function agree(pg, who, gestures, chapterId = 'one') {
  const { course, part, chapter } = await chapterOf(chapterId);
  if (chapterId === 'two') await unlock(pg, who);
  const started = await call(pg, who, 'start', ['toy', chapterId]);
  if (started.refused) throw new Error(started.refused);
  const server = dbServer(pg, who, chapterId);
  const lesson = createLesson({ course, part, chapter, adapter, server, state: started.state });
  const differ = [];
  let n = 0;
  for (const [i, g] of gestures.entries()) {
    if ((await lesson.play(g)).kind === 'done') continue;
    n++;
    const a = counters(lesson.state());
    const b = counters(server.last);
    const board = server.last.played.join(' ');
    if (JSON.stringify(a) !== JSON.stringify(b) || lesson.board() !== board) differ.push({ i, gesture: g, page: a, db: b, board: lesson.board(), played: board });
  }
  return { n, differ };
}

/**
 * A chapter finished and played again, then the page reloaded onto the row (createLesson resumed at its state, and
 * `reconcile` of a page that kept playing): the page's counters are the row's, and a wrong move afterwards counts the same
 * on both. {same, resumed, page, db, reconciled}.
 */
export async function reloaded(pg, who) {
  const { course, part, chapter } = await chapterOf('one');
  await call(pg, who, 'start', ['toy', 'one']);
  await call(pg, who, 'move', ['toy', 'one', 0, 'a1']);
  await call(pg, who, 'move', ['toy', 'one', 2, 'zz']);
  await call(pg, who, 'move', ['toy', 'one', 2, 'zz']);
  await call(pg, who, 'move', ['toy', 'one', 2, 'a2']);
  await call(pg, who, 'move', ['toy', 'one', 4, 'a3']);
  const row = (await call(pg, who, 'start', ['toy', 'one'])).state;
  const server = dbServer(pg, who, 'one');
  const lesson = createLesson({ course, part, chapter, adapter, server, state: row });
  const resumed = counters(lesson.state());
  await lesson.play('zz');
  const db = counters(server.last);
  const page = counters(lesson.state());
  // A page that went on while the server stood: its step is behind, and the server's wins.
  const behind = createLesson({ course, part, chapter, adapter, state: { step: 0, wrongs: 0, step_wrongs: 0, pool_said: 0, over: false, played: [] } });
  const reconciled = counters(behind.reconcile(server.last));
  return { same: JSON.stringify(page) === JSON.stringify(db) && JSON.stringify(resumed) === JSON.stringify(counters(row)) && JSON.stringify(reconciled) === JSON.stringify(db), resumed, page, db, reconciled };
}

/** The page's lines for wrong moves, as the page picks them from the emitted courses: the keys, in order. */
export async function pickedKeys(count) {
  const courses = await page();
  const course = courses.toy;
  const part = course.parts[0];
  const server = fakeServer();
  const lesson = createLesson({ course, part, chapter: part.chapters[0], adapter, server, state: server.row() });
  await lesson.play('a1');
  const keys = [];
  for (let i = 0; i < count; i++) keys.push((await lesson.play('zz')).line);
  return keys;
}

/** What the emitted page holds of the fixture's script: whether any move of any chapter is in its text, and each chapter's plies. */
export async function pageHolds() {
  const courses = await page();
  const text = JSON.stringify(courses);
  const moves = ['a1', 'b1', 'a2', 'b2', 'a3', "b'1$"];
  const plies = {};
  for (const p of courses.toy.parts) for (const c of p.chapters) plies[c.id] = { plies: c.plies, hasMoves: 'moves' in c };
  return { leaked: moves.filter((m) => text.includes(JSON.stringify(m))), plies };
}

/** Whether every key of the emitted page has its line in each locale's entries, and the keys of each locale. */
export async function catalogues() {
  const keys = [];
  (function walk(v) {
    if (typeof v === 'string' && v.startsWith('lesson_')) keys.push(v);
    else if (v && typeof v === 'object') Object.values(v).forEach(walk);
  })(await page());
  const out = { keys: keys.length, missing: {}, count: {} };
  for (const [loc, text] of Object.entries(emit().messages)) {
    const entries = JSON.parse(`{${text}}`);
    out.count[loc] = Object.keys(entries).length;
    out.missing[loc] = keys.filter((k) => typeof entries[k] !== 'string' || entries[k] === '');
  }
  return out;
}

/** What lessons.nu's `catalogue` does to a catalogue's text for the fixture's courses: this is a copy of it in JS (nu is not
 * what these cases run), so a change to one is a change to the other. An empty `{}` is filled; a layout other than the one
 * JSON.stringify(_, null, 2) makes throws, never a second copy of an entry. */
export function rewrite(text, locale) {
  const { courses, messages } = emit();
  if (courses.length === 0) return text;
  const empty = /^\{\s*\}\s*$/.test(text);
  const dropped = courses.reduce((t, c) => t.replace(new RegExp(`^  "lesson_${c}_[a-z0-9_]+": .*\\n`, 'gm'), ''), text);
  for (const c of courses) if (new RegExp(`"lesson_${c}_[a-z0-9_]+"\\s*:`).test(dropped)) throw new Error(`lessons: a catalogue entry lesson_${c}_* is not laid out with two spaces, one a line`);
  const trim = /,?\s*\n\}\s*$/;
  if (!empty && !trim.test(dropped)) throw new Error('lessons: a catalogue must end with a `}` on a line of its own');
  const kept = empty ? '{' : dropped.replace(trim, '');
  const entries = messages[locale];
  if (!entries) return `${kept}\n}\n`;
  return kept.endsWith('{') ? `${kept}\n${entries}\n}\n` : `${kept},\n${entries}\n}\n`;
}

/** Whether `cue vet -c` accepts two courses: the fixture with its chapter `one_b` called `x_ch_b`, and a copy of it as the course
 * `toy_ch_x` whose `one_b` is called `second`: with `b` as `second` both say the key lesson_toy_ch_x_ch_b_intro. */
export function vetsTwo(second) {
  const text = Deno.readTextFileSync(`${here}fixtures/lessons_course.cue`);
  const dir = pkg(text.replace('id: "one_b"', 'id: "x_ch_b"'), text.replace('courses: toy:', 'courses: toy_ch_x:').replace('id: "one_b"', `id: "${second}"`));
  try {
    return new Deno.Command(Deno.env.get('CUE') ?? 'cue', { args: ['vet', '-c', '.'], cwd: dir, stdout: 'piped', stderr: 'piped' }).outputSync().success;
  } finally {
    Deno.removeSync(dir, { recursive: true });
  }
}

/** The keys of a catalogue's text, in order: the first three, how many are the fixture course's, whether an old one is
 * left, and the last. */
export function keysOf(text) {
  const keys = Object.keys(JSON.parse(text));
  return { first: keys.slice(0, 3), toy: keys.filter((k) => k.startsWith('lesson_toy_')).length, old: keys.includes('lesson_toy_old'), last: keys.at(-1) };
}

/** Whether `cue vet -c` accepts the fixture course with `from` replaced by `to` (a constraint of the plugin's, such as a
 * token of the spec's quoting or an id too long for the row's). */
export function vets(from, to) {
  const text = Deno.readTextFileSync(`${here}fixtures/lessons_course.cue`);
  if (!text.includes(from)) throw new Error(`the fixture has no ${JSON.stringify(from)}`);
  const dir = pkg(text.replace(from, to));
  try {
    return new Deno.Command(Deno.env.get('CUE') ?? 'cue', { args: ['vet', '-c', '.'], cwd: dir, stdout: 'piped', stderr: 'piped' }).outputSync().success;
  } finally {
    Deno.removeSync(dir, { recursive: true });
  }
}
