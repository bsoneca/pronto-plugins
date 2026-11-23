// The keys service on PGlite, under the table an app's migrations would leave (app_user) and a gate and
// a hook of the app's own, as the fork's auth is tested: its routes, its refusals, and what a token says.
import { PGlite } from "npm:@electric-sql/pglite@0.3.7";
import { assert, assertEquals, assertMatch, assertNotEquals } from "jsr:@std/assert@1";
import { type Config, configFrom, type Db, keys, KEY_TOKEN_TTL_S, MAX_LIVE_KEYS, migrate, sign, STACK_ISSUER, verify } from "./keys.ts";

const SECRET = "stack-secret-for-the-tests";
const ANA = "0a000000-0000-4000-8000-000000000001";
const BEN = "0b000000-0000-4000-8000-000000000002";
const BASE: Config = { secret: SECRET, keysOn: true, gate: null, hook: null, appSchema: "public", mechaSchema: "mecha" };

const inOneHour = () => Math.floor(Date.now() / 1000) + 3600;
const session = (sub: string, more: Record<string, unknown> = {}, secret = SECRET) =>
  sign(secret, { role: "app_user", iss: STACK_ISSUER, sub, handle: "h" + sub.slice(1, 3), guest: false, exp: inOneHour(), ...more });

async function stand(cfg: Partial<Config> = {}) {
  const pg = new PGlite();
  await pg.exec(`
    CREATE TABLE public.app_user (id uuid primary key, handle text not null);
    INSERT INTO public.app_user VALUES ('${ANA}', 'ana'), ('${BEN}', 'ben');
    CREATE TABLE public.bot_mark (owner uuid, at timestamptz default now());
    CREATE FUNCTION public.keys_on(owner uuid) RETURNS boolean LANGUAGE sql AS $$ SELECT owner <> '${BEN}' $$;
    CREATE FUNCTION public.keys_used(owner uuid) RETURNS void LANGUAGE plpgsql AS $$
      BEGIN
        IF owner = '${BEN}' THEN RAISE EXCEPTION 'no bots'; END IF;
        INSERT INTO public.bot_mark (owner) VALUES (owner);
      END $$;
  `);
  const db: Db = {
    query: async (t, p) => (await pg.query(t, p ?? [])).rows as Record<string, unknown>[],
    tx: (fn) => pg.transaction((tx) => fn(async (t, p) => (await tx.query(t, p ?? [])).rows as Record<string, unknown>[])),
  };
  const conf = { ...BASE, ...cfg };
  await migrate(db, conf);
  const handle = keys(conf, db);
  const call = (method: string, path: string, token?: string, body?: unknown) =>
    handle(new Request("http://keys" + path, {
      method,
      headers: { ...(token ? { authorization: `Bearer ${token}` } : {}), "content-type": "application/json" },
      body: body === undefined || method === "GET" ? undefined : JSON.stringify(body),
    }));
  return { pg, db, call, conf };
}

async function made(call: Awaited<ReturnType<typeof stand>>["call"], who = ANA, scopes = ["read"], label = "bot") {
  const r = await call("POST", "/auth/keys", await session(who), { label, scopes });
  assertEquals(r.status, 201);
  return await r.json() as { id: string; key: string; scopes: string[] };
}

Deno.test("a key is made once, kept only as its hash, listed without it, exchanged and revoked", async () => {
  const { pg, call } = await stand();
  const k = await made(call, ANA, ["read", "machines:bot_1"]);
  assertMatch(k.key, /^pk_live_[A-Za-z0-9_-]{43}$/);
  assertEquals(k.scopes, ["read", "machines:bot_1"]);
  const rows = (await pg.query("select sha256, encode(sha256, 'hex') as h from mecha_auth.api_key")).rows as { h: string }[];
  assertEquals(rows.length, 1);
  assertEquals(rows[0].h, [...new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(k.key)))].map((b) => b.toString(16).padStart(2, "0")).join(""));
  const list = await (await call("GET", "/auth/keys", await session(ANA))).json();
  assertEquals(list.keys.length, 1);
  assertEquals(Object.keys(list.keys[0]).sort(), ["created_at", "id", "label", "last_used", "scopes"]);
  assert(!JSON.stringify(list).includes(k.key));

  const ex = await call("POST", "/auth/key", undefined, { key: k.key });
  assertEquals(ex.status, 200);
  const { token, expires_in } = await ex.json();
  assertEquals(expires_in, KEY_TOKEN_TTL_S);
  const claims = await verify(SECRET, token);
  assertEquals(claims?.sub, ANA);
  assertEquals(claims?.kid, k.id);
  assertEquals(claims?.scp, ["read", "machines:bot_1"]);
  assertEquals(claims?.role, "app_user");
  assertEquals(claims?.iss, STACK_ISSUER);
  assertEquals(claims?.guest, false);
  assertEquals((claims!.exp as number) - Math.floor(Date.now() / 1000) <= KEY_TOKEN_TTL_S, true);
  const used = (await call("GET", "/auth/keys", await session(ANA)).then((r) => r.json())).keys[0].last_used;
  assertNotEquals(used, null);

  assertEquals((await call("DELETE", `/auth/keys/${k.id}`, await session(BEN))).status, 404);
  assertEquals((await call("DELETE", `/auth/keys/${k.id}`, await session(ANA))).status, 204);
  assertEquals((await call("DELETE", `/auth/keys/${k.id}`, await session(ANA))).status, 404);
  assertEquals((await call("POST", "/auth/key", undefined, { key: k.key })).status, 401);
});

Deno.test("an unknown, revoked or malformed key is one 401", async () => {
  const { call } = await stand();
  const k = await made(call);
  await call("DELETE", `/auth/keys/${k.id}`, await session(ANA));
  for (const key of [k.key, "pk_live_" + "A".repeat(43), "mk_other", "", 7, "pk_live_" + "A".repeat(300)]) {
    const r = await call("POST", "/auth/key", undefined, { key });
    assertEquals([r.status, (await r.json()).error], [401, "invalid key"]);
  }
  assertEquals((await call("POST", "/auth/key", undefined, "not json")).status, 401);
});

Deno.test("who may hold keys: an account's own session, not a guest, a key's token or an upgraded one", async () => {
  const { call } = await stand();
  const k = await made(call);
  const key = await (await call("POST", "/auth/key", undefined, { key: k.key })).json();
  const body = { label: "x", scopes: ["read"] };
  const cases: [string | undefined, number, string][] = [
    [undefined, 401, "invalid token"],
    ["garbage", 401, "invalid token"],
    [await session(ANA, {}, "another secret"), 401, "invalid token"],
    [await session(ANA, { exp: 1 }), 401, "invalid token"],
    [await session(ANA, { role: "service" }), 401, "invalid token"],
    [await session("not-a-uuid"), 401, "invalid token"],
    [await session(ANA, { guest: true }), 403, "guest"],
    [await session(ANA, { acr: "0" }), 403, "guest"],
    [key.token, 403, "key token"],
    [await session(ANA, { operation_kind: "payout" }), 403, "upgraded token"],
    [await session(ANA, { amr: ["pwd"] }), 403, "upgraded token"],
  ];
  for (const [token, status, error] of cases) {
    for (const [method, path, b] of [["POST", "/auth/keys", body], ["GET", "/auth/keys", undefined], ["DELETE", `/auth/keys/${k.id}`, undefined]] as const) {
      const r = await call(method, path, token, b);
      assertEquals([r.status, (await r.json()).error], [status, error], `${method} ${path} ${error}`);
    }
  }
  assertEquals((await call("GET", "/auth/keys", await session(ANA, { acr: "phr" }))).status, 200);
});

Deno.test("a token signed another way, or with no exp, is no session", async () => {
  const { call } = await stand();
  const enc = (o: unknown) => btoa(JSON.stringify(o)).replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/, "");
  const claims = enc({ role: "app_user", sub: ANA, exp: inOneHour() });
  const none = `${enc({ alg: "none" })}.${claims}.`;
  const rs = `${enc({ alg: "RS256" })}.${claims}.AAAA`;
  const noExp = await sign(SECRET, { role: "app_user", sub: ANA });
  const strExp = await sign(SECRET, { role: "app_user", sub: ANA, exp: String(inOneHour()) });
  for (const t of [none, rs, noExp, strExp]) assertEquals((await call("GET", "/auth/keys", t)).status, 401);
});

Deno.test("a make is checked: label, scopes and at most five live keys, a revoke frees one", async () => {
  const { call } = await stand();
  const t = await session(ANA);
  for (const b of [{}, { label: "", scopes: ["read"] }, { label: " ", scopes: ["read"] }, { label: "x".repeat(65), scopes: ["read"] }, { label: "x" }, { label: "x", scopes: [] }, { label: "x", scopes: ["admin"] }, { label: "x", scopes: ["machines:Bad"] }, { label: "x", scopes: [1] }, { label: "x", scopes: "read" }]) {
    assertEquals((await call("POST", "/auth/keys", t, b)).status, 400, JSON.stringify(b));
  }
  assertEquals((await call("POST", "/auth/keys", t, [1])).status, 400);
  const first = await made(call, ANA, ["read", "read", "write"]);
  assertEquals(first.scopes, ["read", "write"]);
  for (let i = 1; i < MAX_LIVE_KEYS; i++) await made(call);
  const over = await call("POST", "/auth/keys", t, { label: "x", scopes: ["read"] });
  assertEquals([over.status, (await over.json()).error], [409, `at most ${MAX_LIVE_KEYS} live keys`]);
  assertEquals((await call("POST", "/auth/keys", await session(BEN), { label: "x", scopes: ["read"] })).status, 201);
  await call("DELETE", `/auth/keys/${first.id}`, t);
  assertEquals((await call("POST", "/auth/keys", t, { label: "x", scopes: ["read"] })).status, 201);
  assertEquals((await call("DELETE", "/auth/keys/not-a-uuid", t)).status, 404);
});

Deno.test("an app's gate answers for the caller and for the key's owner; a revoke is never refused", async () => {
  const { call } = await stand({ gate: "public.keys_on" });
  const k = await made(call, ANA);
  assertEquals((await call("POST", "/auth/keys", await session(BEN), { label: "x", scopes: ["read"] })).status, 404);
  assertEquals((await call("GET", "/auth/keys", await session(BEN))).status, 404);
  assertEquals((await call("DELETE", `/auth/keys/${k.id}`, await session(BEN))).status, 404, "another's key, not the gate");
  // Ben's key exists from before the gate: made without one, then asked under it.
  const open = await stand();
  const bk = await made(open.call, BEN);
  const gated = keys({ ...BASE, gate: "public.keys_on" }, open.db);
  const r = await gated(new Request("http://keys/auth/key", { method: "POST", body: JSON.stringify({ key: bk.key }) }));
  assertEquals(r.status, 404);
  const rv = await gated(new Request(`http://keys/auth/keys/${bk.id}`, { method: "DELETE", headers: { authorization: `Bearer ${await session(BEN)}` } }));
  assertEquals(rv.status, 204);
  assertEquals((await call("POST", "/auth/key", undefined, { key: k.key })).status, 200);
});

Deno.test("an app's hook runs on every exchange before the token, and a hook that throws issues none and leaves no use", async () => {
  const { pg, call } = await stand({ hook: "public.keys_used" });
  const k = await made(call, ANA);
  assertEquals((await call("POST", "/auth/key", undefined, { key: k.key })).status, 200);
  assertEquals((await call("POST", "/auth/key", undefined, { key: k.key })).status, 200);
  assertEquals((await pg.query("select count(*)::int as n from public.bot_mark where owner = $1", [ANA])).rows[0], { n: 2 });
  const bk = await made(call, BEN);
  const r = await call("POST", "/auth/key", undefined, { key: bk.key });
  assertEquals(r.status, 500);
  assertEquals((await r.json()).error, "internal error");
  assertEquals((await pg.query("select last_used from mecha_auth.api_key where id = $1", [bk.id])).rows[0], { last_used: null });
  // Making and listing never call it.
  await call("GET", "/auth/keys", await session(ANA));
  assertEquals((await pg.query("select count(*)::int as n from public.bot_mark")).rows[0], { n: 2 });
});

Deno.test("with keys off every key route is 404 and no table is made, the door still answers", async () => {
  const { pg, call } = await stand({ keysOn: false });
  for (const [m, p] of [["POST", "/auth/keys"], ["GET", "/auth/keys"], ["DELETE", `/auth/keys/${ANA}`], ["POST", "/auth/key"]]) {
    assertEquals((await call(m, p, await session(ANA), { key: "pk_live_x" })).status, 404, `${m} ${p}`);
  }
  assertEquals((await pg.query("select to_regclass('mecha_auth.api_key') as t")).rows[0], { t: null });
  assertEquals((await call("GET", "/auth/door", await session(ANA))).headers.get("x-pronto-account"), ANA);
  assertEquals((await call("GET", "/auth/nothing")).status, 404);
});

Deno.test("the door always answers 204, naming the account only of a live session", async () => {
  const { call } = await stand();
  const sent = async (token?: string) => {
    const r = await call("GET", "/auth/door", token);
    assertEquals(r.status, 204);
    assertEquals(await r.text(), "");
    return r.headers.get("x-pronto-account");
  };
  assertEquals(await sent(await session(ANA)), ANA);
  assertEquals(await sent(await session("guest-1_a", { guest: true })), "guest-1_a", "a guest is an account of the door's");
  for (const t of [undefined, "garbage", await session(ANA, {}, "another secret"), await session(ANA, { exp: 1 }), await session(ANA, { role: "service" }), await session("a b")]) {
    assertEquals(await sent(t), null);
  }
  assertEquals(await sent(await session("x".repeat(65))), null);
  const r = await call("POST", "/auth/door", await session(ANA));
  assertEquals(r.status, 404);
});

Deno.test("the table is made once, beside an app's own, and where it is the migration changes nothing", async () => {
  const { pg, db, conf } = await stand();
  const k = await made((await stand()).call);
  assert(k.id);
  await pg.exec(`INSERT INTO mecha_auth.api_key (id, owner, label, scopes, sha256) VALUES ('${crypto.randomUUID()}', '${BEN}', 'old', ARRAY['read'], '\\x01')`);
  await migrate(db, conf);
  await migrate(db, conf);
  assertEquals((await pg.query("select count(*)::int as n from mecha_auth.api_key")).rows[0], { n: 1 });
  // The reader by hash is owner-only: no one else is granted it.
  const acl = (await pg.query("select proacl::text as a from pg_proc where proname = 'api_key_owner'")).rows[0] as { a: string | null };
  assert(acl.a === null || !acl.a.startsWith("="), `execute is held back from PUBLIC: ${acl.a}`);
});

Deno.test("the environment is held to what the fork's auth holds it to", () => {
  const env = (v: Record<string, string>) => (n: string) => v[n];
  const ok = { PGRST_JWT_SECRET: "s" };
  assertEquals(configFrom(env(ok)).keysOn, false);
  assertEquals(configFrom(env({ ...ok, AUTH_API_KEYS: "true", AUTH_API_KEYS_GATE: "a.b", AUTH_KEY_EXCHANGED_HOOK: "c.d" })), { secret: "s", keysOn: true, gate: "a.b", hook: "c.d", appSchema: "public", mechaSchema: "mecha" });
  for (const bad of [{ PGRST_JWT_SECRET: "" }, { ...ok, AUTH_API_KEYS: "yes" }, { ...ok, AUTH_API_KEYS_GATE: "nodot" }, { ...ok, AUTH_API_KEYS_GATE: 'a.b"; drop table x; --' }, { ...ok, AUTH_KEY_EXCHANGED_HOOK: "A.b" }, { ...ok, MECHA_DB_SCHEMA: "x; y" }, { ...ok, MECHA_SCHEMA: "Mecha" }]) {
    let said = "";
    try {
      configFrom(env(bad));
    } catch (e) {
      said = (e as Error).message;
    }
    assertNotEquals(said, "", JSON.stringify(bad));
  }
});
