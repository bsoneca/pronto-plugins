// The keys service: an account's API keys and the door's account check, for an app on a mecha whose
// auth service has neither (mecha 0.32 serves no `/auth/keys*` and no `/auth/door`). It matches the
// fork's auth service (README.md here) route for route, signs with the stack's secret and reads
// `mecha_auth.api_key` in place, so no key moves. The handlers take a `Db`, so the tests run them on
// PGlite and main.ts on Postgres.

const enc = new TextEncoder();
const dec = new TextDecoder();

/** One statement with `$n` parameters, its rows back. */
export type Query = (text: string, params?: unknown[]) => Promise<Record<string, unknown>[]>;
export type Db = { query: Query; tx<T>(fn: (q: Query) => Promise<T>): Promise<T> };

export type Config = {
  /** The stack's HS256 secret (PGRST_JWT_SECRET): the auth service's own. */
  secret: string;
  /** AUTH_API_KEYS: off, every key route answers 404. */
  keysOn: boolean;
  /** AUTH_API_KEYS_GATE, `schema.name(owner uuid) returns boolean`. */
  gate: string | null;
  /** AUTH_KEY_EXCHANGED_HOOK, `schema.name(owner uuid) returns void`. */
  hook: string | null;
  /** MECHA_DB_SCHEMA: where `app_user` is. */
  appSchema: string;
  /** MECHA_SCHEMA: where `rls_exempt` is. */
  mechaSchema: string;
};

/** The `iss` every token the stack signs carries (mecha's STACK_ISSUER): the tenancy floor admits the
 * cluster's roles only from a token naming it. */
export const STACK_ISSUER = "mecha:stack";
export const KEY_PREFIX = "pk_live_";
export const KEY_TOKEN_TTL_S = 900;
export const MAX_LIVE_KEYS = 5;
const KEY_SCOPE = /^(read|write|machines:[a-z][a-z0-9_]{0,62})$/;
const KEY_LABEL_MAX = 64;
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const PLAIN = /^[a-z_][a-z0-9_]*$/;
const NAMED = /^[a-z_][a-z0-9_]*\.[a-z_][a-z0-9_]*$/;
// Claims of `/auth/upgrade`'s tokens; a session carrying one is an upgraded session. Not `amr` or `idp`:
// in 0.32 a passkey's or a provider's session carries `amr` as any session does.
const UPGRADED = ["operation_kind", "operation_id"];
const BODY_MAX = 4096;

/** A configuration read from the environment, refusing what the fork's auth refuses at start. */
export function configFrom(env: (name: string) => string | undefined): Config {
  const secret = env("PGRST_JWT_SECRET");
  if (!secret) throw new Error("PGRST_JWT_SECRET is required");
  const raw = env("AUTH_API_KEYS") ?? "";
  if (raw !== "" && raw !== "true" && raw !== "false") throw new Error(`AUTH_API_KEYS must be true or false, not ${raw}`);
  const named = (name: string): string | null => {
    const v = env(name) ?? "";
    if (v === "") return null;
    if (!NAMED.test(v)) throw new Error(`${name} must name a function as schema.name, not ${v}`);
    return v;
  };
  const schema = (name: string, fallback: string): string => {
    const v = env(name) || fallback;
    if (!PLAIN.test(v)) throw new Error(`${name} is ${v}, not a schema name`);
    return v;
  };
  return {
    secret,
    keysOn: raw === "true",
    gate: named("AUTH_API_KEYS_GATE"),
    hook: named("AUTH_KEY_EXCHANGED_HOOK"),
    appSchema: schema("MECHA_DB_SCHEMA", "public"),
    mechaSchema: schema("MECHA_SCHEMA", "mecha"),
  };
}

// --- HS256, over WebCrypto ---

const b64u = (bytes: Uint8Array): string => {
  let s = "";
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s).replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/, "");
};
const unb64u = (text: string): Uint8Array<ArrayBuffer> => {
  const s = atob(text.replaceAll("-", "+").replaceAll("_", "/"));
  return Uint8Array.from(s, (c) => c.charCodeAt(0));
};
const hmacKey = (secret: string) => crypto.subtle.importKey("raw", enc.encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign", "verify"]);

export async function sign(secret: string, claims: Record<string, unknown>): Promise<string> {
  const head = b64u(enc.encode(JSON.stringify({ alg: "HS256", typ: "JWT" })));
  const body = b64u(enc.encode(JSON.stringify(claims)));
  const mac = new Uint8Array(await crypto.subtle.sign("HMAC", await hmacKey(secret), enc.encode(`${head}.${body}`)));
  return `${head}.${body}.${b64u(mac)}`;
}

/** The claims of a live HS256 token of this secret, else null: the header must say HS256, the MAC must
 * hold and `exp` must be a number in the future. */
export async function verify(secret: string, token: string): Promise<Record<string, unknown> | null> {
  const parts = token.split(".");
  if (parts.length !== 3) return null;
  try {
    const head = JSON.parse(dec.decode(unb64u(parts[0])));
    if (head?.alg !== "HS256") return null;
    if (!(await crypto.subtle.verify("HMAC", await hmacKey(secret), unb64u(parts[2]), enc.encode(`${parts[0]}.${parts[1]}`)))) return null;
    const claims = JSON.parse(dec.decode(unb64u(parts[1])));
    if (typeof claims !== "object" || claims === null || typeof claims.exp !== "number") return null;
    return claims.exp <= Math.floor(Date.now() / 1000) ? null : claims;
  } catch {
    return null;
  }
}

// --- Responses ---

const json = (status: number, body: unknown): Response =>
  new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json", "cache-control": "no-store" } });
const fail = (status: number, error: string): Response => json(status, { error });
const notFound = () => fail(404, "not found");

/** The JSON object of a body of at most BODY_MAX bytes, else null: read as it arrives, never whole. */
async function readBody(req: Request): Promise<Record<string, unknown> | null> {
  try {
    const declared = Number(req.headers.get("content-length") ?? 0);
    if (!(declared <= BODY_MAX) || req.body === null) return null;
    const chunks: Uint8Array[] = [];
    let size = 0;
    for await (const chunk of req.body) {
      size += chunk.length;
      if (size > BODY_MAX) return null;
      chunks.push(chunk);
    }
    const bytes = new Uint8Array(size);
    let at = 0;
    for (const c of chunks) {
      bytes.set(c, at);
      at += c.length;
    }
    const body = JSON.parse(dec.decode(bytes));
    return typeof body === "object" && body !== null && !Array.isArray(body) ? body : null;
  } catch {
    return null;
  }
}

const hex = async (text: string): Promise<string> =>
  [...new Uint8Array(await crypto.subtle.digest("SHA-256", enc.encode(text)))].map((b) => b.toString(16).padStart(2, "0")).join("");

const newKey = (): string => KEY_PREFIX + b64u(crypto.getRandomValues(new Uint8Array(32)));

/** A schema.name quoted, for a statement. configFrom holds the name to a plain `schema.name`. */
const quoted = (name: string): string => name.split(".").map((p) => `"${p}"`).join(".");

/** The statements that make the table, its owner-only reader and its exemption from the tenancy floor,
 * where absent (the fork's apiKeysSql), one a statement. Where an app's migration made it, nothing
 * changes. `mecha_auth` is the auth service's own schema: no app role reaches it. */
export const tableSql = ({ appSchema, mechaSchema }: Pick<Config, "appSchema" | "mechaSchema">): string[] => [
  "CREATE SCHEMA IF NOT EXISTS mecha_auth",
  `CREATE TABLE IF NOT EXISTS mecha_auth.api_key (
  id uuid primary key,
  owner uuid not null references "${appSchema}".app_user(id) on delete cascade,
  label text not null,
  scopes text[] not null,
  sha256 bytea not null unique,
  created_at timestamptz not null default now(),
  last_used timestamptz,
  revoked_at timestamptz
)`,
  "CREATE INDEX IF NOT EXISTS api_key_owner_live ON mecha_auth.api_key (owner) WHERE revoked_at IS NULL",
  `CREATE OR REPLACE FUNCTION mecha_auth.api_key_owner(hash bytea)
  RETURNS TABLE (id uuid, owner uuid, handle text, scopes text[])
  LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog AS $fn$
    SELECT k.id, k.owner, u.handle, k.scopes FROM mecha_auth.api_key k JOIN "${appSchema}".app_user u ON u.id = k.owner
      WHERE k.sha256 = hash AND k.revoked_at IS NULL
  $fn$`,
  "REVOKE ALL ON FUNCTION mecha_auth.api_key_owner(bytea) FROM PUBLIC",
  `DO $x$ BEGIN
  IF to_regclass('"${mechaSchema}".rls_exempt') IS NOT NULL THEN
    INSERT INTO "${mechaSchema}".rls_exempt VALUES ('mecha_auth.api_key', 'the auth service''s own table, in a schema no app role may use')
      ON CONFLICT DO NOTHING;
  END IF;
END $x$`,
];

/** Makes the table where it is not, one process at a time; nothing where keys are off. */
export async function migrate(db: Db, cfg: Config): Promise<void> {
  if (!cfg.keysOn) return;
  await db.tx(async (q) => {
    await q("select pg_advisory_xact_lock(hashtext('pronto-keys:migrate'))");
    // Where the auth service or an app's migration made the table and its reader, they stay as they are: they
    // may belong to another role, which could not replace them.
    const [have] = await q("select to_regclass('mecha_auth.api_key') is not null and to_regprocedure('mecha_auth.api_key_owner(bytea)') is not null as made");
    if (have?.made === true) return;
    for (const statement of tableSql(cfg)) await q(statement);
  });
}

// --- The handlers ---

type Claims = Record<string, unknown>;
type Subject = { claims: Claims | null } | "refused";

/** A request's subject, as the fork's auth sees it: no claims when no token was sent, refused when a
 * token was sent and is not a live app_user session of this secret. */
async function subjectOf(cfg: Config, req: Request): Promise<Subject> {
  const auth = req.headers.get("authorization");
  if (!auth) return { claims: null };
  if (!auth.startsWith("Bearer ")) return "refused";
  const claims = await verify(cfg.secret, auth.slice("Bearer ".length));
  return claims && claims.role === "app_user" ? { claims } : "refused";
}

/** A guest, in the fork's claim (`guest`) and in upstream's (`acr` "0", OpenID's level 0). */
const isGuest = (c: Claims): boolean => c.guest === true || c.acr === "0";
const isUpgraded = (c: Claims): boolean => UPGRADED.some((k) => k in c);

/** GET /auth/door (Caddy's forward_auth): always 204; the session's account in `x-pronto-account` only
 * for a live session, so a signed-out visitor, a bad or foreign token gets none and the door sends its
 * own "no account" value. */
export async function door(cfg: Config, req: Request): Promise<Response> {
  const subject = await subjectOf(cfg, req);
  const sub = subject !== "refused" && subject.claims ? subject.claims.sub : null;
  const headers = new Headers();
  if (typeof sub === "string" && /^[A-Za-z0-9_-]{1,64}$/.test(sub)) headers.set("x-pronto-account", sub);
  return new Response(null, { status: 204, headers });
}

/** GET /auth/keyguard, for the door's forward_auth before every other `/auth/*` path: 403 for a key's token,
 * else 204. 0.32's auth takes any session, a key's token among them, and its rename answers a session with
 * no `kid`, so a key could make keys of its own that outlive it; the door refuses a key's token there. */
export async function keyguard(cfg: Config, req: Request): Promise<Response> {
  const subject = await subjectOf(cfg, req);
  if (subject !== "refused" && subject.claims && "kid" in subject.claims) return fail(403, "key token");
  return new Response(null, { status: 204 });
}

/** The caller who may hold keys: a signed-in account's own session. A key's token, an upgraded one and
 * a guest are refused, so a key never makes or revokes another. */
async function holder(cfg: Config, req: Request): Promise<{ id: string } | Response> {
  const subject = await subjectOf(cfg, req);
  if (subject === "refused" || subject.claims === null) return fail(401, "invalid token");
  const c = subject.claims;
  if (typeof c.sub !== "string" || !UUID.test(c.sub)) return fail(401, "invalid token");
  if (isGuest(c)) return fail(403, "guest");
  if (c.kid !== undefined) return fail(403, "key token");
  if (isUpgraded(c)) return fail(403, "upgraded token");
  return { id: c.sub };
}

async function allowed(cfg: Config, q: Query, owner: string): Promise<boolean> {
  if (cfg.gate === null) return true;
  const [row] = await q(`select ${quoted(cfg.gate)}($1::uuid) as on`, [owner]);
  return row?.on === true;
}

async function createKey(cfg: Config, db: Db, req: Request): Promise<Response> {
  const who = await holder(cfg, req);
  if (who instanceof Response) return who;
  if (!(await allowed(cfg, db.query, who.id))) return notFound();
  const body = await readBody(req);
  const label = body?.label;
  const scopes = body?.scopes;
  if (typeof label !== "string" || label.trim() === "" || label.length > KEY_LABEL_MAX) {
    return fail(400, `label required, at most ${KEY_LABEL_MAX} characters`);
  }
  if (!Array.isArray(scopes) || scopes.length === 0 || !scopes.every((s) => typeof s === "string" && KEY_SCOPE.test(s))) {
    return fail(400, "scopes required: read, write or machines:<name>");
  }
  const key = newKey();
  const hash = await hex(key);
  const made = await db.tx(async (q) => {
    // One account's creates one at a time, so two at once cannot both take the last place.
    await q("select pg_advisory_xact_lock(hashtext($1))", ["api_key:" + who.id]);
    const [n] = await q("select count(*)::int as live from mecha_auth.api_key where owner = $1 and revoked_at is null", [who.id]);
    if ((n.live as number) >= MAX_LIVE_KEYS) return null;
    const [row] = await q(
      `insert into mecha_auth.api_key (id, owner, label, scopes, sha256)
       values ($1, $2, $3, array(select jsonb_array_elements_text($4::jsonb)), decode($5, 'hex'))
       returning id, label, scopes, created_at`,
      [crypto.randomUUID(), who.id, label, JSON.stringify([...new Set(scopes as string[])]), hash],
    );
    return row;
  });
  if (made === null) return fail(409, `at most ${MAX_LIVE_KEYS} live keys`);
  return json(201, { id: made.id, key, label: made.label, scopes: made.scopes, created_at: made.created_at });
}

async function listKeys(cfg: Config, db: Db, req: Request): Promise<Response> {
  const who = await holder(cfg, req);
  if (who instanceof Response) return who;
  if (!(await allowed(cfg, db.query, who.id))) return notFound();
  const rows = await db.query(
    `select id, label, scopes, created_at, last_used from mecha_auth.api_key
     where owner = $1 and revoked_at is null order by created_at, id`,
    [who.id],
  );
  return json(200, { keys: rows });
}

/** The caller's own live key, revoked; another's, or one already revoked, is 404. Never gated. */
async function revokeKey(cfg: Config, db: Db, req: Request, id: string): Promise<Response> {
  const who = await holder(cfg, req);
  if (who instanceof Response) return who;
  if (!UUID.test(id)) return fail(404, "no such key");
  const [row] = await db.query(
    "update mecha_auth.api_key set revoked_at = now() where id = $1 and owner = $2 and revoked_at is null returning id",
    [id, who.id],
  );
  return row ? new Response(null, { status: 204 }) : fail(404, "no such key");
}

/** POST /auth/key {key}: a live key for a user token of its owner, 15 minutes long, carrying the key's
 * id (`kid`) and scopes (`scp`). An unknown, revoked or malformed key is the same 401. */
async function exchangeKey(cfg: Config, db: Db, req: Request): Promise<Response> {
  const key = (await readBody(req))?.key;
  if (typeof key !== "string" || !key.startsWith(KEY_PREFIX) || key.length > 256) return fail(401, "invalid key");
  const [k] = await db.query("select id, owner, handle, scopes from mecha_auth.api_key_owner(decode($1, 'hex'))", [await hex(key)]);
  if (!k) return fail(401, "invalid key");
  const owner = k.owner as string;
  if (!(await allowed(cfg, db.query, owner))) return notFound();
  // The use and the hook are one transaction: a hook that throws leaves no use and issues no token.
  // A key revoked since it was read is no key: the update names a live one.
  const live = await db.tx(async (q) => {
    const [used] = await q("update mecha_auth.api_key set last_used = now() where id = $1 and revoked_at is null returning id", [k.id]);
    if (!used) return false;
    if (cfg.hook !== null) await q(`select ${quoted(cfg.hook)}($1::uuid)`, [owner]);
    return true;
  });
  if (!live) return fail(401, "invalid key");
  const token = await sign(cfg.secret, {
    role: "app_user",
    iss: STACK_ISSUER,
    sub: owner,
    handle: k.handle,
    guest: false,
    kid: k.id,
    scp: k.scopes,
    exp: Math.floor(Date.now() / 1000) + KEY_TOKEN_TTL_S,
  });
  return json(200, { token, expires_in: KEY_TOKEN_TTL_S });
}

/** The service's handler. Paths carry their `/auth` prefix. */
export function keys(cfg: Config, db: Db): (req: Request) => Promise<Response> {
  return async (req) => {
    const path = new URL(req.url).pathname;
    try {
      if (req.method === "GET" && path === "/auth/door") return await door(cfg, req);
      if (req.method === "GET" && path === "/auth/keyguard") return await keyguard(cfg, req);
      if (cfg.keysOn) {
        if (req.method === "POST" && path === "/auth/keys") return await createKey(cfg, db, req);
        if (req.method === "GET" && path === "/auth/keys") return await listKeys(cfg, db, req);
        const revoke = req.method === "DELETE" ? /^\/auth\/keys\/([^/]+)$/.exec(path) : null;
        if (revoke) return await revokeKey(cfg, db, req, revoke[1]);
        if (req.method === "POST" && path === "/auth/key") return await exchangeKey(cfg, db, req);
      }
      return notFound();
    } catch (e) {
      console.error(e);
      return fail(500, "internal error");
    }
  };
}
