// pronto-api's generator (api/generate.ts) and its lint (api/lint.ts) on a stand-in app: the
// fixture (tests/unit/api-fixture/, three entities) copied to a folder of its own with the plugin's
// api_plugin.cue beside it, as an install would leave it, then edited, generated and released.
// Its views run on PGlite under the tables a program like the fixture's would have, as the
// fixture's users; its door runs in caddy (on PATH, or CADDY) in front of a stand-in PostgREST that
// answers what it was asked. cue is the one on PATH, or CUE.
import { PGlite } from 'npm:@electric-sql/pglite@0.3.7';
import { check, generate, route } from '../../api/generate.ts';
import { named } from '../../api/lint.ts';

const here = new URL('.', import.meta.url).pathname;

/** A fresh copy of the fixture app, its path. */
export async function app() {
  const dir = await Deno.makeTempDir({ prefix: 'api-app-' });
  for await (const e of Deno.readDir(`${here}api-fixture`)) await Deno.copyFile(`${here}api-fixture/${e.name}`, `${dir}/${e.name}`);
  const plugin = await Deno.readTextFile(`${here}../../api/app/api_plugin.cue`);
  await Deno.writeTextFile(`${dir}/api_plugin.cue`, plugin.replaceAll('__PACKAGE__', 'fixture'));
  return dir;
}

/** `from` replaced by `to` in the app's `file` (it must be there); the app's path. */
export async function edit(dir, file, from, to) {
  const text = await Deno.readTextFile(`${dir}/${file}`);
  if (!text.includes(from)) throw new Error(`${file} has no ${JSON.stringify(from)}`);
  await Deno.writeTextFile(`${dir}/${file}`, text.replace(from, to));
  return dir;
}

/** The API generated in the app: its SQL, routes, contract and door. */
export const generated = (dir) => generate(dir);

/** The contract generated last, frozen as the release's; the app's path. */
export async function release(dir) {
  await Deno.copyFile(`${dir}/api/v1/contract.json`, `${dir}/api/v1/released.json`);
  return dir;
}

/** What the generated contract breaks of the released one. */
export const checked = (dir) => check(dir);

/** The files generate wrote, as text: sql, contract, openapi and door. */
export async function files(dir) {
  const out = {};
  for (const [k, f] of Object.entries({ sql: 'api/v1/api_v1.sql', contract: 'api/v1/contract.json', openapi: 'api/v1/openapi.json', door: 'api_door.cue' })) out[k] = await Deno.readTextFile(`${dir}/${f}`);
  return out;
}

export const ADA = '0b0b0b0b-0000-4000-8000-00000000000a';
export const BOB = '0b0b0b0b-0000-4000-8000-00000000000b';

// The fixture's tables as an app's migrations would leave them, with mecha's roles: a note is its
// owner's alone (RLS), its stars a CHECK (a CEL check) keeps between 0 and 5, and its created has no
// default of its own (as guestbook's entry), so the view's Create stamps it.
const TABLES = `
CREATE ROLE anon NOLOGIN; CREATE ROLE app_user NOLOGIN;
CREATE FUNCTION public.auth_uid() RETURNS uuid LANGUAGE sql STABLE AS $$ SELECT nullif(current_setting('request.jwt.claims', true)::json->>'sub', '')::uuid $$;
CREATE TABLE public.note (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), owner_id uuid NOT NULL DEFAULT public.auth_uid(), body text, stars int CHECK (stars BETWEEN 0 AND 5), created timestamptz NOT NULL);
ALTER TABLE public.note ENABLE ROW LEVEL SECURITY;
CREATE POLICY own ON public.note TO app_user USING (owner_id = public.auth_uid()) WITH CHECK (owner_id = public.auth_uid());
GRANT SELECT, INSERT, UPDATE, DELETE ON public.note TO app_user;
CREATE TABLE public.tag (id uuid PRIMARY KEY, label text, old text);
GRANT SELECT ON public.tag TO app_user, anon;
CREATE TABLE public.note_tag (id uuid PRIMARY KEY, note_id uuid REFERENCES public.note, label text);
GRANT SELECT ON public.note_tag TO app_user;
CREATE SCHEMA pronto_flags; CREATE TABLE pronto_flags.stub_on (player uuid PRIMARY KEY);
CREATE FUNCTION pronto_flags.flag_on(flag text, player uuid DEFAULT NULL) RETURNS boolean LANGUAGE sql STABLE AS $$ SELECT flag = 'api_export' AND EXISTS (SELECT 1 FROM pronto_flags.stub_on s WHERE s.player = flag_on.player) $$;
INSERT INTO public.tag VALUES ('0b0b0b0b-0000-4000-8000-0000000000f1', 'red', NULL), ('0b0b0b0b-0000-4000-8000-0000000000f2', 'blue', NULL);
`;

/** The app's database: the fixture's tables, then the generated api_v1.sql, replayed twice as every
 * release replays it. */
export async function db(dir) {
  const pg = new PGlite();
  await pg.exec(TABLES);
  const sql = await Deno.readTextFile(`${dir}/api/v1/api_v1.sql`);
  await pg.exec(sql);
  await pg.exec(sql);
  return pg;
}

/** pronto-flags' api_export turned on for the account `uid` (the fixture's stand-in of its
 * flag_on); "on". */
export async function flagOn(pg, uid) {
  await pg.query('INSERT INTO pronto_flags.stub_on VALUES ($1)', [uid]);
  return 'on';
}

/** A value of the app's package, as cue exports it. */
export async function exported(dir, expr) {
  const r = await new Deno.Command(Deno.env.get('CUE') ?? 'cue', { args: ['export', '.', '-e', expr, '--out', 'json'], cwd: dir, stdout: 'piped', stderr: 'piped' }).output();
  if (!r.success) throw new Error(new TextDecoder().decode(r.stderr).trim());
  return JSON.parse(new TextDecoder().decode(r.stdout));
}

/** A door Caddyfile as pronto writes one (an (app) snippet with an earlier plugin's block before
 * /auth), with the API's block routed into it, then routed again: the file each time. */
export async function caddyRouted(dir) {
  const before = '(app) {\n  handle /crud/* {\n    reverse_proxy crud:3000\n  }\n  # flags:begin\n  handle /ofrep/* {\n  }\n  # flags:end\n  # The auth service.\n  handle /auth/* {\n  }\n}\n';
  await Deno.mkdir(`${dir}/docker`, { recursive: true });
  await Deno.writeTextFile(`${dir}/docker/Caddyfile`, before);
  await route(dir);
  const once = await Deno.readTextFile(`${dir}/docker/Caddyfile`);
  await route(dir);
  return { once, twice: await Deno.readTextFile(`${dir}/docker/Caddyfile`) };
}

/** pronto-api installed in a copy of the fixture with no api plugin of its own: the files it wrote,
 * then installed again over an api_spec.cue the app changed. */
export async function installed() {
  const dir = await Deno.makeTempDir({ prefix: 'api-install-' });
  await Deno.writeTextFile(`${dir}/program.cue`, 'package fixture\n');
  const run = async () => {
    const r = await new Deno.Command(Deno.execPath(), { args: ['run', '--no-config', '--allow-read', '--allow-write', `${here}../../api/install.ts`, dir], stdout: 'piped', stderr: 'piped' }).output();
    if (!r.success) throw new Error(new TextDecoder().decode(r.stderr));
    return new TextDecoder().decode(r.stdout).trim().split('\n').filter(Boolean);
  };
  const first = await run();
  await Deno.writeTextFile(`${dir}/api_spec.cue`, 'package fixture\n\napi: entities: {}\n');
  const again = await run();
  const text = async (f) => await Deno.readTextFile(`${dir}/${f}`);
  return { first, again, spec: await text('api_spec.cue'), plugin: (await text('api_plugin.cue')).split('\n')[1], rules: await text('pronto/api.cue'), generator: (await text('api/generate.ts')).split('\n')[0] };
}

/** The app's api_v1.sql as generated now, replayed over a database that has the last one, as the
 * next release replays it; "replayed". */
export async function replayed(pg, dir) {
  try {
    await pg.exec(await Deno.readTextFile(`${dir}/api/v1/api_v1.sql`));
  } catch (e) {
    throw new Error(`${e.code ?? '?'}: ${e.message}`);
  }
  return 'replayed';
}

/** `sql` run as the user `uid` (app_user with its claims) or, with uid "anon", as anon: the rows,
 * or a throw of "<SQLSTATE>: <message>". */
export async function as(pg, uid, sql, params = []) {
  try {
    return await pg.transaction(async (tx) => {
      await tx.exec(uid === 'anon' ? 'SET LOCAL ROLE anon' : 'SET LOCAL ROLE app_user');
      await tx.query("SELECT set_config('request.jwt.claims', $1, true)", [JSON.stringify(uid === 'anon' ? { role: 'anon' } : { sub: uid, role: 'app_user' })]);
      return (await tx.query(sql, params)).rows;
    });
  } catch (e) {
    throw new Error(`${e.code ?? '?'}: ${e.message}`);
  }
}

/** The app's door: caddy serving the generated block in front of a stand-in PostgREST that answers
 * each request with what reached it (method, path and query, the profile and Prefer headers). */
export async function door(dir) {
  const upstream = Deno.serve({ port: 0, hostname: '127.0.0.1', onListen() {} }, (req) => {
    const u = new URL(req.url);
    const h = (n) => req.headers.get(n);
    return Response.json({ method: req.method, path: u.pathname, query: u.search, accept_profile: h('accept-profile'), content_profile: h('content-profile'), prefer: h('prefer'), accept: h('accept'), range: h('range'), content_type: h('content-type') });
  });
  const text = await Deno.readTextFile(`${dir}/api_door.cue`);
  const block = /apiDoor: caddy: """\n([\s\S]*?)\n\t"""/.exec(text)[1].replace(/^\t/gm, '');
  const port = freePort();
  const conf = await Deno.makeTempFile({ suffix: '.Caddyfile' });
  await Deno.writeTextFile(conf, `{\n  admin off\n  auto_https off\n}\n(bounded-crud) {\n}\nhttp://127.0.0.1:${port} {\n${block}\n  handle {\n    respond "shell" 200\n  }\n}\n`);
  const child = new Deno.Command(Deno.env.get('CADDY') ?? 'caddy', { args: ['run', '--config', conf, '--adapter', 'caddyfile'], env: { PRONTO_UPSTREAM_CRUD: `127.0.0.1:${upstream.addr.port}` }, stdout: 'null', stderr: 'null' }).spawn();
  const url = `http://127.0.0.1:${port}`;
  for (let i = 0; ; i++) {
    try {
      await (await fetch(`${url}/`)).body?.cancel();
      break;
    } catch {
      if (i > 100) throw new Error('caddy did not start');
      await new Promise((r) => setTimeout(r, 100));
    }
  }
  return { url, stop: async () => { child.kill(); await child.status; await upstream.shutdown(); } };
}

function freePort() {
  const l = Deno.listen({ hostname: '127.0.0.1', port: 0 });
  const p = l.addr.port;
  l.close();
  return p;
}

/** One call through the door: the status, and what the stand-in PostgREST saw (null when the door
 * answered itself). */
export async function call(d, method, path, headers = {}) {
  const r = await fetch(`${d.url}${path}`, { method, headers: { 'Content-Type': 'application/json', ...headers }, body: method === 'GET' || method === 'DELETE' ? undefined : '{}' });
  const text = await r.text();
  let seen = null;
  try { seen = JSON.parse(text); } catch { /* the door's own answer */ }
  return { status: r.status, seen };
}

/** The door stopped; "stopped". */
export async function stopped(d) {
  await d.stop();
  return 'stopped';
}

/** The plugin's api/ (or a copy with `planted` written into a file of its own) held to the lint. */
export async function linted(words, planted) {
  const api = `${here}../../api`;
  if (planted === undefined) return await named(api, words);
  const dir = await Deno.makeTempDir({ prefix: 'api-lint-' });
  await new Deno.Command('cp', { args: ['-R', `${api}/.`, dir] }).output();
  await Deno.writeTextFile(`${dir}/planted.ts`, `export const table = "${planted}";\n`);
  return await named(dir, words);
}
