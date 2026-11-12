// Everything the broker keeps between requests, in one place, so any replica can answer any request:
// the one-time codes (sign-in's and the phone's), the phone's visits and their wrong-guess counts and
// resend waits, and the keys the broker signs with. Two implementations of one interface:
//
// - MemoryStore: one process's own, the default (no DATABASE_URL): the tests, a local broker and the
//   Cloud Run release, which stays at one instance.
// - PostgresStore: a database of the broker's own (DATABASE_URL, metal.nu's `identity-db`). Every
//   operation that must not happen twice, a code redeemed twice, a wrong guess uncounted, two texts
//   inside the wait, a second key, is one SQL statement, so two replicas cannot both win it.
//
// The broker has no migration runner, so it creates its two tables itself at start, idempotently
// (CREATE TABLE IF NOT EXISTS, tried again if a replica starting at the same moment made a table first).
// Values are JSON text; the broker never reads one with SQL.
import { base64url, type Jwk, jwkThumbprint } from "../oidc.ts";

export interface Store {
  /** Keep `value` under (kind, key) for `ttlMs`, replacing any earlier one and its wrong-guess count. */
  put(kind: string, key: string, value: unknown, ttlMs: number): Promise<void>;
  get<T>(kind: string, key: string): Promise<T | undefined>;
  /** Get and delete at once: of two callers, one gets the value. */
  take<T>(kind: string, key: string): Promise<T | undefined>;
  del(kind: string, key: string): Promise<void>;
  /** Count one more wrong guess against a held value: the new count, or undefined when none is held. */
  bump(kind: string, key: string): Promise<number | undefined>;
  /** Hold (kind, key) for `ttlMs` unless it is held already: true for the one caller that got it. */
  claim(kind: string, key: string, ttlMs: number): Promise<boolean>;
  /** Milliseconds (kind, key) is still held, 0 when it is not. */
  left(kind: string, key: string): Promise<number>;
  /** A value made once for the whole deployment: the first caller's `make` wins, every other caller gets that one. */
  once(name: string, make: () => string | Promise<string>): Promise<string>;
}

export class MemoryStore implements Store {
  #held = new Map<string, { value: string; expires: number; tries: number }>();
  #once = new Map<string, string>();
  constructor(readonly now: () => number = Date.now) {}

  #live(kind: string, key: string) {
    const id = `${kind}\u0000${key}`;
    const held = this.#held.get(id);
    if (held && held.expires <= this.now()) {
      this.#held.delete(id);
      return undefined;
    }
    return held;
  }
  put(kind: string, key: string, value: unknown, ttlMs: number): Promise<void> {
    for (const [id, h] of this.#held) if (h.expires <= this.now()) this.#held.delete(id);
    this.#held.set(`${kind}\u0000${key}`, { value: JSON.stringify(value), expires: this.now() + ttlMs, tries: 0 });
    return Promise.resolve();
  }
  get<T>(kind: string, key: string): Promise<T | undefined> {
    const h = this.#live(kind, key);
    return Promise.resolve(h ? JSON.parse(h.value) as T : undefined);
  }
  take<T>(kind: string, key: string): Promise<T | undefined> {
    const h = this.#live(kind, key);
    this.#held.delete(`${kind}\u0000${key}`);
    return Promise.resolve(h ? JSON.parse(h.value) as T : undefined);
  }
  del(kind: string, key: string): Promise<void> {
    this.#held.delete(`${kind}\u0000${key}`);
    return Promise.resolve();
  }
  bump(kind: string, key: string): Promise<number | undefined> {
    const h = this.#live(kind, key);
    return Promise.resolve(h ? ++h.tries : undefined);
  }
  claim(kind: string, key: string, ttlMs: number): Promise<boolean> {
    if (this.#live(kind, key)) return Promise.resolve(false);
    this.#held.set(`${kind}\u0000${key}`, { value: "null", expires: this.now() + ttlMs, tries: 0 });
    return Promise.resolve(true);
  }
  left(kind: string, key: string): Promise<number> {
    const h = this.#live(kind, key);
    return Promise.resolve(h ? h.expires - this.now() : 0);
  }
  async once(name: string, make: () => string | Promise<string>): Promise<string> {
    const made = this.#once.get(name) ?? await make();
    if (!this.#once.has(name)) this.#once.set(name, made);
    return this.#once.get(name)!;
  }
}

/** The part of postgres.js the store uses: a statement with `$n` parameters, its rows back. */
export interface Sql {
  unsafe(query: string, params?: unknown[]): Promise<Record<string, unknown>[]>;
  end?(): Promise<void>;
}

export const SCHEMA = [
  `CREATE TABLE IF NOT EXISTS broker_kv (
    kind text NOT NULL, key text NOT NULL, value text NOT NULL,
    expires timestamptz NOT NULL, tries integer NOT NULL DEFAULT 0,
    PRIMARY KEY (kind, key)
  )`,
  `CREATE INDEX IF NOT EXISTS broker_kv_expires ON broker_kv (expires)`,
  `CREATE TABLE IF NOT EXISTS broker_once (name text PRIMARY KEY, value text NOT NULL)`,
];

// Each ttl is `make_interval(secs => $n / 1000)`: milliseconds in, the database's own clock out.
export const SQL = {
  sweep: `DELETE FROM broker_kv WHERE ctid IN (SELECT ctid FROM broker_kv WHERE expires <= now() LIMIT 100)`,
  put: `INSERT INTO broker_kv (kind, key, value, expires, tries) VALUES ($1, $2, $3, now() + make_interval(secs => $4::double precision / 1000), 0)
    ON CONFLICT (kind, key) DO UPDATE SET value = EXCLUDED.value, expires = EXCLUDED.expires, tries = 0`,
  get: `SELECT value FROM broker_kv WHERE kind = $1 AND key = $2 AND expires > now()`,
  take: `DELETE FROM broker_kv WHERE kind = $1 AND key = $2 AND expires > now() RETURNING value`,
  del: `DELETE FROM broker_kv WHERE kind = $1 AND key = $2`,
  bump: `UPDATE broker_kv SET tries = tries + 1 WHERE kind = $1 AND key = $2 AND expires > now() RETURNING tries`,
  claim: `INSERT INTO broker_kv (kind, key, value, expires, tries) VALUES ($1, $2, 'null', now() + make_interval(secs => $3::double precision / 1000), 0)
    ON CONFLICT (kind, key) DO UPDATE SET expires = EXCLUDED.expires, value = EXCLUDED.value, tries = 0
    WHERE broker_kv.expires <= now() RETURNING 1 AS claimed`,
  left: `SELECT (extract(epoch FROM expires - now()) * 1000)::double precision AS ms FROM broker_kv WHERE kind = $1 AND key = $2 AND expires > now()`,
  onceGet: `SELECT value FROM broker_once WHERE name = $1`,
  onceSet: `INSERT INTO broker_once (name, value) VALUES ($1, $2) ON CONFLICT (name) DO NOTHING`,
};

export class PostgresStore implements Store {
  constructor(readonly sql: Sql) {}

  /** Connect to `url` and make sure the tables are there. */
  static async connect(url: string): Promise<PostgresStore> {
    const { default: postgres } = await import("./vendor/postgres.js");
    const store = new PostgresStore(postgres(url, { max: 5, idle_timeout: 30, connect_timeout: 10, onnotice: () => {} }) as unknown as Sql);
    await store.migrate();
    return store;
  }

  async migrate(): Promise<void> {
    // Replicas starting together can both find a table missing, and one's CREATE then fails on the
    // other's; the second try finds it there.
    for (let attempt = 1;; attempt++) {
      try {
        for (const statement of SCHEMA) await this.sql.unsafe(statement);
        return;
      } catch (e) {
        if (attempt >= 3) throw e;
      }
    }
  }

  async put(kind: string, key: string, value: unknown, ttlMs: number): Promise<void> {
    // Expired rows go as new ones arrive: a bounded few at a time, so no request pays for a backlog.
    await this.sql.unsafe(SQL.sweep);
    await this.sql.unsafe(SQL.put, [kind, key, JSON.stringify(value), ttlMs]);
  }
  async get<T>(kind: string, key: string): Promise<T | undefined> {
    const [row] = await this.sql.unsafe(SQL.get, [kind, key]);
    return row ? JSON.parse(String(row.value)) as T : undefined;
  }
  async take<T>(kind: string, key: string): Promise<T | undefined> {
    const [row] = await this.sql.unsafe(SQL.take, [kind, key]);
    return row ? JSON.parse(String(row.value)) as T : undefined;
  }
  async del(kind: string, key: string): Promise<void> {
    await this.sql.unsafe(SQL.del, [kind, key]);
  }
  async bump(kind: string, key: string): Promise<number | undefined> {
    const [row] = await this.sql.unsafe(SQL.bump, [kind, key]);
    return row ? Number(row.tries) : undefined;
  }
  async claim(kind: string, key: string, ttlMs: number): Promise<boolean> {
    const rows = await this.sql.unsafe(SQL.claim, [kind, key, ttlMs]);
    return rows.length > 0;
  }
  async left(kind: string, key: string): Promise<number> {
    const [row] = await this.sql.unsafe(SQL.left, [kind, key]);
    return row ? Math.max(0, Math.ceil(Number(row.ms))) : 0;
  }
  async once(name: string, make: () => string | Promise<string>): Promise<string> {
    const [held] = await this.sql.unsafe(SQL.onceGet, [name]);
    if (held) return String(held.value);
    // Two replicas may both make one: the insert keeps the first, and both read that.
    await this.sql.unsafe(SQL.onceSet, [name, await make()]);
    const [won] = await this.sql.unsafe(SQL.onceGet, [name]);
    return String(won.value);
  }
}

/** The broker's store: the database at DATABASE_URL when there is one, else this process's memory. */
export function storeFrom(env: (k: string) => string | undefined): Promise<Store> {
  const url = env("DATABASE_URL");
  return url ? PostgresStore.connect(url) : Promise.resolve(new MemoryStore());
}

/**
 * A signing key every replica shares: made once (by the first to ask) and kept in the store as its
 * private JWK. Its `kid` is the public key's RFC 7638 thumbprint, so a changed key is a new kid.
 */
export async function sharedKeyPair(store: Store, name: string, alg: "ES256" | "RS256"): Promise<{ privateKey: CryptoKey; jwk: Jwk & { alg: string; use: string } }> {
  const algorithm = alg === "ES256"
    ? { name: "ECDSA", namedCurve: "P-256" }
    : { name: "RSASSA-PKCS1-v1_5", modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: "SHA-256" };
  const held = JSON.parse(await store.once(name, async () => {
    const made = await crypto.subtle.generateKey(algorithm, true, ["sign", "verify"]);
    return JSON.stringify(await crypto.subtle.exportKey("jwk", made.privateKey));
  })) as Jwk;
  const privateKey = await crypto.subtle.importKey("jwk", held, alg === "ES256" ? { name: "ECDSA", namedCurve: "P-256" } : { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" }, false, ["sign"]);
  const pub: Jwk = alg === "ES256" ? { kty: held.kty, crv: held.crv, x: held.x, y: held.y } : { kty: held.kty, n: held.n, e: held.e };
  return { privateKey, jwk: { ...pub, kid: await jwkThumbprint(pub), alg, use: "sig" } };
}

/** A random secret every replica shares, made once (see `once`). */
export function sharedSecret(store: Store, name: string, bytes: number): Promise<string> {
  return store.once(name, () => base64url(crypto.getRandomValues(new Uint8Array(bytes))));
}
