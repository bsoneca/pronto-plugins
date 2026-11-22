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
// The broker runs no DDL: its tables are made by billing/broker/schema.sql (add-only, idempotent), which
// `metal.nu release` applies to the broker's own database before replacing the broker: broker/schema.sql is the
// schema that initializes the broker database, and the one place to point an operator at. It is declared once, in
// SCHEMA below, and schema_gen.ts emits it. It is never an app's migration: the broker's database is the
// operator's, and an app's roles must not reach these tables. The store only checks at start that they are there.

import { RULES } from "../rules.ts";

const [CLAIMED, DONE] = RULES.claimStates;
const STATES = RULES.claimStates.map((x) => `'${x}'`).join(", ");

// A row's life as rules.cue's claimTransitions declare it: both stores ask `step` what an event does to
// the state it finds, and the SQL names its states by `target`, so the declaration is the one owner.
export type RowState = typeof RULES.claimStates[number];
type Where = RowState | "absent";
type ClaimEvent = typeof RULES.claimTransitions[number]["event"];

/** The state `event` leaves a row in that is `from` ("absent": no row, or one whose time ended), or null when
 * the declaration refuses it: `holds` says whether the caller names the row's current token. */
export function step(event: ClaimEvent, from: Where, holds: boolean): Where | null {
  const t = RULES.claimTransitions.find((x) => x.event === event && x.from === from);
  return !t || (t.token === "holder" && !holds) ? null : t.to;
}

/** The state `event` leaves a row `from` in, which the declaration must have: the SQL's own words for it. */
export function target(event: ClaimEvent, from: Where): Where {
  const to = step(event, from, true);
  if (to === null) throw new Error(`rules.cue declares no ${event} of a row ${from}`);
  return to;
}

/** What a claim came to: this caller's (with its token), another's still running, or finished for good. */
export type Claim = { state: "claimed"; token: string } | { state: "busy" } | { state: "done" };

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
  /** Take (kind, id) for `leaseMs`, for one caller of all the replicas: claimed (with the token of this claim),
   * busy (another holds it, its lease not yet ended) or done (finished: `complete`, or `remember`). The state
   * is kept beside the expiry, never read off the time left: expiry only decides when a claim may be taken
   * again, so a finished event stays done to the end of its retention. */
  claim(kind: string, id: string, leaseMs: number): Promise<Claim>;
  /** Mark the claim `token` names finished, remembered for `ttlMs`: whether it was the live current claim (a
   * newer one, a lease that ended, or a release leaves the row as it is and answers false). */
  complete(kind: string, id: string, token: string, ttlMs: number): Promise<boolean>;
  /** Forget (kind, id) now. With `token`: the holder's release of its claim (a newer claim, a remember or another
   * caller's token leaves the row). Without: a cache invalidation of a finished row, never of a claim in progress. */
  forget(kind: string, id: string, token?: string): Promise<boolean>;
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
  #seen = new Map<string, { until: number; state: RowState; token?: string }>();
  #claimed = 0;
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
  /** How many rows are held, live or not yet swept. */
  get rows(): number {
    return this.#seen.size;
  }
  #cursor: Iterator<[string, { until: number; state: RowState; token?: string }]> | null = null;
  /** Drops rows whose time ended by the declared `expire`: at most SWEEP looked at a call, continuing where the
   * last call stopped, so no caller pays for a backlog and no row is skipped for ever. */
  #sweep(): void {
    for (let n = 0; n < SWEEP; n++) {
      this.#cursor ??= this.#seen[Symbol.iterator]();
      const next = this.#cursor.next();
      if (next.done) {
        this.#cursor = null;
        return;
      }
      const [k, held] = next.value;
      if (held.until <= this.now() && step("expire", held.state, false) === "absent") this.#seen.delete(k);
    }
  }
  /** The live row, whose time has not ended. */
  #live(key: string) {
    const held = this.#seen.get(key);
    return held !== undefined && held.until > this.now() ? held : undefined;
  }
  seen(kind: string, id: string): Promise<boolean> {
    return Promise.resolve(this.#live(`${kind}\u0000${id}`) !== undefined);
  }
  remember(kind: string, id: string, ttlMs: number): Promise<void> {
    this.#sweep();
    const key = `${kind}\u0000${id}`;
    this.#seen.set(key, { until: this.now() + ttlMs, state: step("remember", this.#live(key)?.state ?? "absent", false) as RowState });
    return Promise.resolve();
  }
  claim(kind: string, id: string, leaseMs: number): Promise<Claim> {
    this.#sweep();
    const key = `${kind}\u0000${id}`, now = this.now(), held = this.#live(key);
    const to = step("claim", held?.state ?? "absent", false);
    if (to === null) return Promise.resolve({ state: held!.state === DONE ? "done" : "busy" });
    const token = `${now + leaseMs}#${++this.#claimed}`;
    this.#seen.set(key, { until: now + leaseMs, state: to as RowState, token });
    return Promise.resolve({ state: "claimed", token });
  }
  complete(kind: string, id: string, token: string, ttlMs: number): Promise<boolean> {
    const key = `${kind}\u0000${id}`, held = this.#live(key);
    const to = step("complete", held?.state ?? "absent", held?.token === token);
    if (to === null) return Promise.resolve(false);
    this.#seen.set(key, { until: this.now() + ttlMs, state: to as RowState });
    return Promise.resolve(true);
  }
  forget(kind: string, id: string, token?: string): Promise<boolean> {
    const key = `${kind}\u0000${id}`;
    // Without a token, the declared cache invalidation (a finished row, never a claim in progress); with one,
    // the holder's declared release. False when the declaration refused it and the row stays.
    const held = this.#live(key);
    const to = token === undefined ? step("invalidate", held?.state ?? "absent", false) : step("release", held?.state ?? "absent", held?.token === token);
    if (to === "absent" && held) this.#seen.delete(key);
    return Promise.resolve(to === "absent" && held !== undefined);
  }
}

/** The part of postgres.js the store uses: a statement with `$n` parameters, its rows back, and a
 * transaction on one connection. */
export interface Sql {
  unsafe(query: string, params?: unknown[]): Promise<Record<string, unknown>[]>;
  begin<T>(fn: (tx: Sql) => Promise<T>): Promise<T>;
  end?(): Promise<void>;
}

/** How many rows a call may look at to drop the ones whose time ended (rules.cue's claimSweep, for both stores). */
const SWEEP = RULES.claimSweep;
/** The states a row may be in for `event` to apply to it, from the declaration. */
const fromStates = (event: ClaimEvent, to: Where = "absent") =>
  RULES.claimTransitions.filter((t) => t.event === event && t.to === to).map((t) => `'${t.from}'`).join(", ");

/** The tables the broker needs, checked at start. */
const TABLES = ["billing_counter", "billing_window", "billing_seen"];

/** The schema, each statement add-only and idempotent: billing/broker/schema.sql is exactly these, `;`-ended. */
export const SCHEMA = [
  `CREATE TABLE IF NOT EXISTS billing_counter (name text PRIMARY KEY, value bigint NOT NULL)`,
  `CREATE TABLE IF NOT EXISTS billing_window (
    name text NOT NULL, key text NOT NULL, n integer NOT NULL, started timestamptz NOT NULL,
    PRIMARY KEY (name, key)
  )`,
  `CREATE INDEX IF NOT EXISTS billing_window_started ON billing_window (started)`,
  `CREATE TABLE IF NOT EXISTS billing_seen (kind text NOT NULL, id text NOT NULL, expires timestamptz NOT NULL, PRIMARY KEY (kind, id))`,
  `CREATE INDEX IF NOT EXISTS billing_seen_expires ON billing_seen (expires)`,
  // A row says whether it is a claim in progress or finished, beside when it expires; a table made before
  // the column holds only finished rows and remembered ones, so they default to done.
  `ALTER TABLE billing_seen ADD COLUMN IF NOT EXISTS state text NOT NULL DEFAULT '${DONE}'`,
  // The states are rules.cue's claimStates; added once, valid for every row a table made before it holds.
  `DO $$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'billing_seen_state' AND conrelid = 'billing_seen'::regclass) THEN
      ALTER TABLE billing_seen ADD CONSTRAINT billing_seen_state CHECK (state IN (${STATES}));
    END IF;
  END $$`,
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
  remember: `INSERT INTO billing_seen (kind, id, expires, state) VALUES ($1, $2, now() + make_interval(secs => $3::double precision / 1000), '${target("remember", "absent")}')
    ON CONFLICT (kind, id) DO UPDATE SET expires = EXCLUDED.expires, state = '${target("remember", "claimed")}'
    WHERE billing_seen.state IN (${fromStates("remember", "done")}) RETURNING 1 AS remembered`,
  // One statement takes a row nobody holds: absent, or its lease (or memory) ended. The token is the row's
  // expires as text, microseconds and all: a client's Date would round it to milliseconds.
  claim: `INSERT INTO billing_seen (kind, id, expires, state) VALUES ($1, $2, now() + make_interval(secs => $3::double precision / 1000), '${target("claim", "absent")}')
    ON CONFLICT (kind, id) DO UPDATE SET expires = EXCLUDED.expires, state = '${target("claim", "absent")}' WHERE billing_seen.expires <= now()
    RETURNING expires::text AS token`,
  claimed: `SELECT state = '${DONE}' AS done FROM billing_seen WHERE kind = $1 AND id = $2 AND expires > now()`,
  complete: `UPDATE billing_seen SET expires = now() + make_interval(secs => $4::double precision / 1000), state = '${target("complete", "claimed")}'
    WHERE kind = $1 AND id = $2 AND state = '${CLAIMED}' AND expires > now() AND expires::text = $3::text RETURNING 1 AS completed`,
  // With a token, only the holder's live claim is released (the declaration's release); without, the row goes.
  // The declared release (holder's token, a live claim) and invalidation (a finished row only).
  forget: `DELETE FROM billing_seen WHERE kind = $1 AND id = $2 AND $3::text IS NOT NULL AND state IN (${fromStates("release")}) AND expires > now() AND expires::text = $3::text RETURNING 1 AS released`,
  invalidate: `DELETE FROM billing_seen WHERE kind = $1 AND id = $2 AND state IN (${fromStates("invalidate")}) RETURNING 1 AS invalidated`,
  // The declared expiry: rows whose time ended, in the states `expire` names, a bounded few at a time.
  sweepSeen: `DELETE FROM billing_seen WHERE ctid IN (SELECT ctid FROM billing_seen WHERE expires <= now() AND state IN (${fromStates("expire")}) LIMIT ${SWEEP})`,
};

export class PostgresStore implements Store {
  constructor(readonly sql: Sql) {}

  /** Connect to `url` and check that the tables are there: the broker makes none. */
  static async connect(url: string): Promise<PostgresStore> {
    const { default: postgres } = await import("./vendor/postgres.js");
    // A held lock keeps its connection for as long as its Checkout takes: room for several at once.
    const store = new PostgresStore(postgres(url, { max: 10, idle_timeout: 30, connect_timeout: 10, onnotice: () => {} }) as unknown as Sql);
    await store.verify();
    return store;
  }

  /** Fails, naming what is missing, unless the schema (schema.sql) has been applied. */
  async verify(): Promise<void> {
    const missing: string[] = [];
    for (const table of TABLES) {
      const [row] = await this.sql.unsafe(`SELECT to_regclass($1) IS NOT NULL AS there`, [table]);
      if (row?.there !== true) missing.push(`table ${table}`);
    }
    if (!missing.includes("table billing_seen")) {
      const [col] = await this.sql.unsafe(`SELECT 1 AS there FROM information_schema.columns WHERE table_name = 'billing_seen' AND column_name = 'state'`);
      if (!col) missing.push("column billing_seen.state");
      const [check] = await this.sql.unsafe(`SELECT 1 AS there FROM pg_constraint WHERE conname = 'billing_seen_state' AND conrelid = 'billing_seen'::regclass`);
      if (!check) missing.push("constraint billing_seen_state");
    }
    if (missing.length) {
      throw new Error(`billing broker: the database is missing ${missing.join(", ")}: apply broker/schema.sql to the broker database (add-only, idempotent; metal.nu release does it) before the broker starts; the broker makes no tables`);
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
    // One conditional statement; the declaration lets a remember find any state, so it always lands.
    await this.sql.unsafe(SQL.remember, [kind, id, ttlMs]);
  }
  async claim(kind: string, id: string, leaseMs: number): Promise<Claim> {
    // Rows whose time ended are reclaimed here as they are on a remember: a bounded few a call.
    await this.sql.unsafe(SQL.sweepSeen);
    // A row deleted between the two statements leaves neither: the claim is tried again.
    for (let attempt = 0; attempt < 3; attempt++) {
      const [won] = await this.sql.unsafe(SQL.claim, [kind, id, leaseMs]);
      if (won) return { state: "claimed", token: String(won.token) };
      const [held] = await this.sql.unsafe(SQL.claimed, [kind, id]);
      if (held) return { state: held.done === true ? "done" : "busy" } as Claim;
    }
    return { state: "busy" };
  }
  async complete(kind: string, id: string, token: string, ttlMs: number): Promise<boolean> {
    return (await this.sql.unsafe(SQL.complete, [kind, id, token, ttlMs])).length > 0;
  }
  async forget(kind: string, id: string, token?: string): Promise<boolean> {
    // One conditional statement: a stale holder, or a row in the wrong state, deletes nothing and says so.
    return (await this.sql.unsafe(token === undefined ? SQL.invalidate : SQL.forget, token === undefined ? [kind, id] : [kind, id, token])).length > 0;
  }
}

/** The broker's store: the database at DATABASE_URL when there is one, else this process's memory. */
export function storeFrom(env: (k: string) => string | undefined): Promise<Store> {
  const url = env("DATABASE_URL");
  return url ? PostgresStore.connect(url) : Promise.resolve(new MemoryStore());
}
