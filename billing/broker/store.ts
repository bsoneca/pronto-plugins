// What the billing broker keeps between requests, in one place, so any replica can answer any request
// (PRONTO-371): the lock on an account while its Checkout opens, the one subscription a trial's end is
// handled for at a time, the entitlements' version clock, the limits on what a caller nobody signed in
// may ask, the Stripe events already delivered, and the tenants found to have no payouts account yet. Two implementations of one interface, as the
// identity broker's store (identity/broker/store.ts):
//
// - MemoryStore: one process's own, the default (no DATABASE_URL): the tests, a local broker and the
//   Cloud Run release, which stays at one instance.
// - PostgresStore: a database of the broker's own (DATABASE_URL, metal.nu's `<name>-db`). A lock is a
//   Postgres advisory lock held by a transaction, so it goes with the pod that held it; every count is
//   one SQL statement, so two replicas cannot both win it.
//
// The broker has no migration runner, so it creates its tables itself at start, idempotently (CREATE
// TABLE IF NOT EXISTS, tried again if a replica starting at the same moment made a table first).

export interface Store {
  /** Run `fn` while no other caller, in this replica or another, runs one under `key`: callers wait their turn.
   * In Postgres the lock holds a connection for as long as `fn` runs, so `fn` asks Stripe, never the store. */
  locked<T>(key: string, fn: () => Promise<T>): Promise<T>;
  /** Run `fn` unless another caller runs one under `key` now: undefined, and `fn` not run, when one does. */
  exclusive<T>(key: string, fn: () => Promise<T>): Promise<T | undefined>;
  /** A number above every earlier one of `name`, and not below `floor`. */
  tick(name: string, floor: number): Promise<number>;
  /** Count one call of `key` against `per` a `windowMs` of the limit `name`: whether it is within it. */
  take(name: string, key: string, per: number, windowMs: number): Promise<boolean>;
  /** Whether (kind, id) was remembered, and is not yet forgotten. */
  seen(kind: string, id: string): Promise<boolean>;
  /** Remember (kind, id) for `ttlMs`. */
  remember(kind: string, id: string, ttlMs: number): Promise<void>;
  /** Forget (kind, id) now. */
  forget(kind: string, id: string): Promise<void>;
}

/** At most `per` calls a `windowMs` for each key, the oldest keys forgotten past `keys`. */
class Window {
  #seen = new Map<string, { n: number; at: number }>();
  constructor(readonly keys = 10_000, readonly now = () => Date.now()) {}
  take(key: string, per: number, windowMs: number): boolean {
    const t = this.now();
    let held = this.#seen.get(key);
    if (!held || t - held.at >= windowMs) held = { n: 0, at: t };
    this.#seen.delete(key);
    this.#seen.set(key, held);
    if (this.#seen.size > this.keys) this.#seen.delete(this.#seen.keys().next().value!);
    return ++held.n <= per;
  }
}

export class MemoryStore implements Store {
  #queues = new Map<string, Promise<unknown>>();
  #running = new Set<string>();
  #counters = new Map<string, number>();
  #windows = new Map<string, Window>();
  #seen = new Map<string, number>();
  constructor(readonly now: () => number = Date.now) {}

  async locked<T>(key: string, fn: () => Promise<T>): Promise<T> {
    const run = (this.#queues.get(key) ?? Promise.resolve()).then(fn);
    const tail = run.catch(() => {});
    this.#queues.set(key, tail);
    try {
      return await run;
    } finally {
      if (this.#queues.get(key) === tail) this.#queues.delete(key);
    }
  }
  async exclusive<T>(key: string, fn: () => Promise<T>): Promise<T | undefined> {
    if (this.#running.has(key)) return undefined;
    this.#running.add(key);
    try {
      return await fn();
    } finally {
      this.#running.delete(key);
    }
  }
  tick(name: string, floor: number): Promise<number> {
    const next = Math.max((this.#counters.get(name) ?? 0) + 1, floor);
    this.#counters.set(name, next);
    return Promise.resolve(next);
  }
  take(name: string, key: string, per: number, windowMs: number): Promise<boolean> {
    let w = this.#windows.get(name);
    if (!w) this.#windows.set(name, w = new Window(10_000, this.now));
    return Promise.resolve(w.take(key, per, windowMs));
  }
  seen(kind: string, id: string): Promise<boolean> {
    const until = this.#seen.get(`${kind}\u0000${id}`);
    return Promise.resolve(until !== undefined && until > this.now());
  }
  remember(kind: string, id: string, ttlMs: number): Promise<void> {
    for (const [k, until] of this.#seen) if (until <= this.now()) this.#seen.delete(k);
    this.#seen.set(`${kind}\u0000${id}`, this.now() + ttlMs);
    return Promise.resolve();
  }
  forget(kind: string, id: string): Promise<void> {
    this.#seen.delete(`${kind}\u0000${id}`);
    return Promise.resolve();
  }
}

/** The part of postgres.js the store uses: a statement with `$n` parameters, its rows back, and a
 * transaction on one connection. */
export interface Sql {
  unsafe(query: string, params?: unknown[]): Promise<Record<string, unknown>[]>;
  begin<T>(fn: (tx: Sql) => Promise<T>): Promise<T>;
  end?(): Promise<void>;
}

export const SCHEMA = [
  `CREATE TABLE IF NOT EXISTS billing_counter (name text PRIMARY KEY, value bigint NOT NULL)`,
  `CREATE TABLE IF NOT EXISTS billing_window (
    name text NOT NULL, key text NOT NULL, n integer NOT NULL, started timestamptz NOT NULL,
    PRIMARY KEY (name, key)
  )`,
  `CREATE INDEX IF NOT EXISTS billing_window_started ON billing_window (started)`,
  `CREATE TABLE IF NOT EXISTS billing_seen (kind text NOT NULL, id text NOT NULL, expires timestamptz NOT NULL, PRIMARY KEY (kind, id))`,
  `CREATE INDEX IF NOT EXISTS billing_seen_expires ON billing_seen (expires)`,
];

// A lock's key is hashed to the 64-bit number Postgres's advisory locks take, under the broker's own
// prefix. A waiting caller gives up after lock_timeout rather than hold its request for ever.
export const LOCK_WAIT = "30s";
// A window kept longer than any limit's (a minute) and then swept.
const WINDOW_KEEP_S = 3600;
export const SQL = {
  lockWait: `SET LOCAL lock_timeout = '${LOCK_WAIT}'`,
  lock: `SELECT pg_advisory_xact_lock(hashtextextended('billing ' || $1, 0))`,
  tryLock: `SELECT pg_try_advisory_xact_lock(hashtextextended('billing ' || $1, 0)) AS got`,
  tick: `INSERT INTO billing_counter (name, value) VALUES ($1, $2::bigint)
    ON CONFLICT (name) DO UPDATE SET value = greatest(billing_counter.value + 1, $2::bigint) RETURNING value`,
  take: `INSERT INTO billing_window (name, key, n, started) VALUES ($1, $2, 1, now())
    ON CONFLICT (name, key) DO UPDATE SET
      n = CASE WHEN billing_window.started <= now() - make_interval(secs => $3::double precision / 1000) THEN 1 ELSE billing_window.n + 1 END,
      started = CASE WHEN billing_window.started <= now() - make_interval(secs => $3::double precision / 1000) THEN now() ELSE billing_window.started END
    RETURNING n`,
  sweepWindows: `DELETE FROM billing_window WHERE ctid IN (SELECT ctid FROM billing_window WHERE started <= now() - interval '${WINDOW_KEEP_S} seconds' LIMIT 100)`,
  seen: `SELECT 1 AS seen FROM billing_seen WHERE kind = $1 AND id = $2 AND expires > now()`,
  remember: `INSERT INTO billing_seen (kind, id, expires) VALUES ($1, $2, now() + make_interval(secs => $3::double precision / 1000))
    ON CONFLICT (kind, id) DO UPDATE SET expires = EXCLUDED.expires`,
  forget: `DELETE FROM billing_seen WHERE kind = $1 AND id = $2`,
  sweepSeen: `DELETE FROM billing_seen WHERE ctid IN (SELECT ctid FROM billing_seen WHERE expires <= now() LIMIT 100)`,
};

export class PostgresStore implements Store {
  constructor(readonly sql: Sql) {}

  /** Connect to `url` and make sure the tables are there. */
  static async connect(url: string): Promise<PostgresStore> {
    const { default: postgres } = await import("./vendor/postgres.js");
    // A held lock keeps its connection for as long as its Checkout takes: room for several at once.
    const store = new PostgresStore(postgres(url, { max: 10, idle_timeout: 30, connect_timeout: 10, onnotice: () => {} }) as unknown as Sql);
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

  locked<T>(key: string, fn: () => Promise<T>): Promise<T> {
    // The lock is the transaction's: it ends with it, and with the connection of a pod that died.
    return this.sql.begin(async (tx) => {
      await tx.unsafe(SQL.lockWait);
      await tx.unsafe(SQL.lock, [key]);
      return await fn();
    });
  }
  exclusive<T>(key: string, fn: () => Promise<T>): Promise<T | undefined> {
    return this.sql.begin(async (tx) => {
      const [row] = await tx.unsafe(SQL.tryLock, [key]);
      return row?.got === true ? await fn() : undefined;
    });
  }
  async tick(name: string, floor: number): Promise<number> {
    const [row] = await this.sql.unsafe(SQL.tick, [name, Math.floor(floor)]);
    return Number(row.value);
  }
  async take(name: string, key: string, per: number, windowMs: number): Promise<boolean> {
    // Old windows go as new calls come: a bounded few at a time, so no request pays for a backlog.
    await this.sql.unsafe(SQL.sweepWindows);
    const [row] = await this.sql.unsafe(SQL.take, [name, key, windowMs]);
    return Number(row.n) <= per;
  }
  async seen(kind: string, id: string): Promise<boolean> {
    return (await this.sql.unsafe(SQL.seen, [kind, id])).length > 0;
  }
  async remember(kind: string, id: string, ttlMs: number): Promise<void> {
    await this.sql.unsafe(SQL.sweepSeen);
    await this.sql.unsafe(SQL.remember, [kind, id, ttlMs]);
  }
  async forget(kind: string, id: string): Promise<void> {
    await this.sql.unsafe(SQL.forget, [kind, id]);
  }
}

/** The broker's store: the database at DATABASE_URL when there is one, else this process's memory. */
export function storeFrom(env: (k: string) => string | undefined): Promise<Store> {
  const url = env("DATABASE_URL");
  return url ? PostgresStore.connect(url) : Promise.resolve(new MemoryStore());
}
