// The billing broker's store (store.ts): the memory one and the Postgres one (its SQL run on PGlite,
// Postgres compiled to WASM, so no server is needed) hold to the same cases, as the identity broker's
// store tests do. PGlite has one connection, so two Postgres locks at once are shown by the statements
// that take them (an advisory lock held by a transaction); the memory store shows the waiting itself.
import { PGlite } from "npm:@electric-sql/pglite@0.3.7";
import { MemoryStore, PostgresStore, SCHEMA, SQL, type Sql, step, type Store, target } from "./store.ts";
import { schemaSql } from "./schema_gen.ts";
import { RULES } from "../rules.ts";

function assertEquals(a: unknown, b: unknown, m = "") {
  if (JSON.stringify(a) !== JSON.stringify(b)) throw new Error(`${m} expected ${JSON.stringify(b)}, got ${JSON.stringify(a)}`);
}
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

/** PGlite as the part of postgres.js the store uses. */
function pglite(pg: PGlite): Sql {
  const of = (q: { query: PGlite["query"] }): Sql => ({
    unsafe: async (text, params) => (await q.query(text, params ?? [])).rows as Record<string, unknown>[],
    begin: (fn) => pg.transaction((tx) => fn(of(tx))),
  });
  return of(pg);
}

/** The schema as the release (or an app's migration) applies it: the broker itself makes no tables. */
async function applySchema(sql: Sql): Promise<void> {
  for (const statement of SCHEMA) await sql.unsafe(statement);
}

const stores: [string, () => Promise<Store>][] = [
  ["memory", () => Promise.resolve(new MemoryStore())],
  ["postgres", async () => {
    const sql = pglite(new PGlite());
    await applySchema(sql);
    await applySchema(sql); // idempotent: applied again, nothing changes
    const s = new PostgresStore(sql);
    await s.verify();
    return s;
  }],
];

for (const [name, make] of stores) {
  Deno.test(`${name} store: a tick is above every earlier one and never below its floor`, async () => {
    const s = await make();
    const now = Date.now();
    const a = await s.tick("ver", now), b = await s.tick("ver", now), c = await s.tick("ver", now - 5000);
    assertEquals([a, b > a, c > b], [now, true, true]);
    assertEquals(await s.tick("ver", now + 60_000), now + 60_000, "the clock wins once it is ahead");
    assertEquals(await s.tick("other", 1), 1, "names are apart");
  });

  Deno.test(`${name} store: a limit counts each key's calls in its window`, async () => {
    const s = await make();
    const took = [];
    for (let i = 0; i < 4; i++) took.push(await s.take("client", "1.2.3.4", 3, 60_000));
    assertEquals(took, [true, true, true, false]);
    assertEquals(await s.take("client", "5.6.7.8", 3, 60_000), true, "keys are apart");
    assertEquals(await s.take("tenant", "1.2.3.4", 3, 60_000), true, "limits are apart");
    for (let i = 0; i < 2; i++) await s.take("short", "k", 2, 50);
    assertEquals(await s.take("short", "k", 2, 50), false);
    await sleep(80);
    assertEquals(await s.take("short", "k", 2, 50), true, "a new window starts the count again");
  });

  Deno.test(`${name} store: an event is known until it is forgotten or expires`, async () => {
    const s = await make();
    assertEquals(await s.seen("stripe event", "evt_1"), false);
    await s.remember("stripe event", "evt_1", 60_000);
    assertEquals([await s.seen("stripe event", "evt_1"), await s.seen("no account", "evt_1")], [true, false], "kinds are apart");
    await s.forget("stripe event", "evt_1");
    assertEquals(await s.seen("stripe event", "evt_1"), false, "forgotten");
    await s.remember("no account", "https://a.example", 30);
    await sleep(60);
    assertEquals(await s.seen("no account", "https://a.example"), false, "expired");
  });

  Deno.test(`${name} store: a lock runs its callers one after another, and lets go of one that failed`, async () => {
    const s = await make();
    const order: string[] = [];
    const run = (who: string, ms: number) => s.locked("acct", async () => {
      order.push(`${who} in`);
      await sleep(ms);
      order.push(`${who} out`);
      return who;
    });
    assertEquals(await Promise.all([run("a", 30), run("b", 0)]), ["a", "b"]);
    assertEquals(order, ["a in", "a out", "b in", "b out"]);
    const failed = await s.locked("acct", () => Promise.reject(new Error("Stripe is down"))).catch((e) => e.message);
    assertEquals([failed, await s.locked("acct", () => Promise.resolve("after"))], ["Stripe is down", "after"]);
  });
}

Deno.test("memory store: an exclusive caller is skipped while another runs under its key", async () => {
  const s = new MemoryStore();
  let release!: () => void;
  const first = s.exclusive("ending sub_1", () => new Promise<string>((r) => (release = () => r("first"))));
  assertEquals(await s.exclusive("ending sub_1", () => Promise.resolve("second")), undefined, "left to the first");
  assertEquals(await s.exclusive("ending sub_2", () => Promise.resolve("other")), "other", "keys are apart");
  release();
  assertEquals(await first, "first");
  assertEquals(await s.exclusive("ending sub_1", () => Promise.resolve("later")), "later", "free once the first ended");
});

Deno.test("postgres store: two stores on one database share what is in it", async () => {
  const sql = pglite(new PGlite());
  const a = new PostgresStore(sql), b = new PostgresStore(sql);
  await applySchema(sql);
  const v = await a.tick("ver", 1000);
  assertEquals(await b.tick("ver", 1000), v + 1);
  for (let i = 0; i < 2; i++) await a.take("client", "ip", 3, 60_000);
  assertEquals([await b.take("client", "ip", 3, 60_000), await a.take("client", "ip", 3, 60_000)], [true, false], "one count over both");
  await a.remember("stripe event", "evt", 60_000);
  assertEquals(await b.seen("stripe event", "evt"), true);
  assertEquals(await b.exclusive("ending sub", () => Promise.resolve("ran")), "ran");
});

Deno.test("postgres store: the statements are the ones that make the operations atomic", async () => {
  const seen: string[] = [];
  const fake: Sql = {
    unsafe: (q) => {
      seen.push(q.replace(/\s+/g, " "));
      return Promise.resolve(/AS got/.test(q) ? [{ got: false }] : /RETURNING (value|n)/.test(q) ? [{ value: 1, n: 1 }] : []);
    },
    begin: (fn) => {
      seen.push("BEGIN");
      return fn(fake).finally(() => seen.push("COMMIT"));
    },
  };
  const s = new PostgresStore(fake);
  await s.locked("acct", () => Promise.resolve());
  assertEquals(seen.splice(0), ["BEGIN", SQL.lockWait, SQL.lock, "COMMIT"], "a lock is a transaction's, with a bounded wait");
  assertEquals(/pg_advisory_xact_lock\(hashtextextended\('billing ' \|\| \$1, 0\)\)/.test(SQL.lock), true, "under the broker's own prefix");
  assertEquals(await s.exclusive("ending", () => Promise.resolve("ran")), undefined, "a lock another holds skips the caller");
  assertEquals(/pg_try_advisory_xact_lock/.test(seen.join(" ")), true);
  seen.length = 0;
  await s.tick("ver", 5);
  assertEquals(/^INSERT INTO billing_counter .* ON CONFLICT \(name\) DO UPDATE SET value = greatest\(billing_counter\.value \+ 1, \$2::bigint\) RETURNING value$/.test(seen[0]), true, "a tick is one statement");
  seen.length = 0;
  await s.take("client", "ip", 3, 60_000);
  assertEquals(/^DELETE FROM billing_window WHERE ctid IN \(SELECT ctid .* LIMIT \d+\)$/.test(seen[0]), true, "a take first sweeps a bounded few old windows");
  assertEquals(/^INSERT INTO billing_window .* ON CONFLICT \(name, key\) DO UPDATE SET n = CASE .* RETURNING n$/.test(seen[1]), true, "and counts in one statement");
});

// A webhook event is claimed by one caller at a time (PRONTO-371's replicas): each store, and the expiry of
// a lease shown as that store keeps time (the memory one's clock, Postgres's row).
const claimable: [string, () => Promise<{ s: Store; expire: (kind: string, id: string) => Promise<void> }>][] = [
  ["memory", () => {
    let t = 1_000_000;
    const s = new MemoryStore(() => t);
    // A lease's end is the clock moving past it.
    return Promise.resolve({ s, expire: () => { t += 1_000_000; return Promise.resolve(); } });
  }],
  ["postgres", async () => {
    const sql = pglite(new PGlite());
    const s = new PostgresStore(sql);
    await applySchema(sql);
    // PGlite's clock ticks in milliseconds, and a token is the row's expiry as text: let one pass so a new claim's differs.
    return { s, expire: async (kind, id) => { await sleep(5); await sql.unsafe(`UPDATE billing_seen SET expires = now() - interval '1 second' WHERE kind = $1 AND id = $2`, [kind, id]); } };
  }],
];

for (const [name, make] of claimable) {
  Deno.test(`${name} store: two claims at once on one event give one claimed and one busy`, async () => {
    const { s } = await make();
    const got = await Promise.all([s.claim("stripe event", "evt_1", 120_000), s.claim("stripe event", "evt_1", 120_000)]);
    assertEquals(got.map((c) => c.state).sort(), ["busy", "claimed"]);
    assertEquals((await s.claim("stripe event", "evt_other", 120_000)).state, "claimed", "ids are apart");
    assertEquals((await s.claim("no account", "evt_1", 120_000)).state, "claimed", "kinds are apart");
  });

  Deno.test(`${name} store: a remembered event is done, a forgotten claim is claimable again`, async () => {
    const { s } = await make();
    const first = await s.claim("stripe event", "evt_1", 120_000);
    assertEquals(first.state, "claimed");
    await s.remember("stripe event", "evt_1", 7 * 24 * 3600_000);
    assertEquals((await s.claim("stripe event", "evt_1", 120_000)).state, "done", "after remember");
    // A stale token cannot undo what was remembered.
    await s.forget("stripe event", "evt_1", (first as { token: string }).token);
    assertEquals((await s.claim("stripe event", "evt_1", 120_000)).state, "done", "a claim's token does not forget a remember");
    const second = await s.claim("stripe event", "evt_2", 120_000);
    await s.forget("stripe event", "evt_2", (second as { token: string }).token);
    assertEquals((await s.claim("stripe event", "evt_2", 120_000)).state, "claimed", "after forget(token)");
  });

  Deno.test(`${name} store: a completed event is done for its whole retention, even in the last seconds of it`, async () => {
    const { s } = await make();
    const c = await s.claim("stripe event", "evt_1", 120_000) as { token: string };
    // A retention shorter than a lease: the old inference (time left above a lease) read it as busy.
    assertEquals(await s.complete("stripe event", "evt_1", c.token, 60_000), true);
    assertEquals((await s.claim("stripe event", "evt_1", 120_000)).state, "done", "done, not busy");
    assertEquals(await s.complete("stripe event", "evt_1", c.token, 60_000), false, "a finished claim completes no more");
  });

  Deno.test(`${name} store: only the current claim's token completes it`, async () => {
    const { s, expire } = await make();
    const old = await s.claim("stripe event", "evt_1", 120_000) as { token: string };
    await expire("stripe event", "evt_1");
    const newer = await s.claim("stripe event", "evt_1", 120_000) as { token: string };
    assertEquals(await s.complete("stripe event", "evt_1", old.token, 600_000), false, "a stale token completes nothing");
    assertEquals((await s.claim("stripe event", "evt_1", 120_000)).state, "busy", "the newer claim is still the holder");
    assertEquals(await s.complete("stripe event", "evt_1", newer.token, 600_000), true);
    assertEquals((await s.claim("stripe event", "evt_1", 120_000)).state, "done");
    await s.forget("stripe event", "evt_2");
    assertEquals(await s.complete("stripe event", "evt_2", "no such", 600_000), false, "nothing claimed, nothing completed");
  });

  Deno.test(`${name} store: an expired lease is claimable again, and the old claim's token deletes nothing of the new one`, async () => {
    const { s, expire } = await make();
    const old = await s.claim("stripe event", "evt_1", 120_000) as { token: string };
    assertEquals((await s.claim("stripe event", "evt_1", 120_000)).state, "busy");
    await expire("stripe event", "evt_1");
    const newer = await s.claim("stripe event", "evt_1", 120_000) as { state: string; token: string };
    assertEquals([newer.state, newer.token === old.token], ["claimed", false], "a new claim, a new token");
    await s.forget("stripe event", "evt_1", old.token);
    assertEquals((await s.claim("stripe event", "evt_1", 120_000)).state, "busy", "the stale token left the newer claim");
    await s.forget("stripe event", "evt_1", newer.token);
    assertEquals((await s.claim("stripe event", "evt_1", 120_000)).state, "claimed", "its own token lets go");
  });
}

Deno.test("postgres store: claim is one statement that takes only a row nobody holds", async () => {
  const sql: string[] = [];
  const fake: Sql = { unsafe: (q) => { sql.push(q.replace(/\s+/g, " ")); return Promise.resolve([{ token: "2026-11-21 10:00:00.123456+00" }]); }, begin: (fn) => fn(fake) };
  const c = await new PostgresStore(fake).claim("stripe event", "evt", 120_000);
  assertEquals(c, { state: "claimed", token: "2026-11-21 10:00:00.123456+00" }, "the token is the row's own text, microseconds kept");
  assertEquals(/^DELETE FROM billing_seen WHERE ctid IN \(SELECT ctid FROM billing_seen WHERE expires <= now\(\) AND state IN \('claimed', 'done'\) LIMIT 100\)$/.test(sql[0]), true, "a claim first reclaims a bounded few rows whose time ended");
  assertEquals(/^INSERT INTO billing_seen .* ON CONFLICT \(kind, id\) DO UPDATE SET expires = EXCLUDED\.expires, state = 'claimed' WHERE billing_seen\.expires <= now\(\) RETURNING expires::text AS token$/.test(sql[1]), true);
});

Deno.test("postgres store: a table made before the claim state column gets it, and its rows are done", async () => {
  const sql = pglite(new PGlite());
  await sql.unsafe(`CREATE TABLE billing_seen (kind text NOT NULL, id text NOT NULL, expires timestamptz NOT NULL, PRIMARY KEY (kind, id))`);
  await sql.unsafe(`INSERT INTO billing_seen VALUES ('stripe event', 'evt_old', now() + interval '3 days')`);
  const s = new PostgresStore(sql);
  await applySchema(sql);
  await applySchema(sql);
  assertEquals((await s.claim("stripe event", "evt_old", 120_000)).state, "done", "an old row is a finished one");
});

Deno.test("postgres store: the broker makes no tables and says what is missing", async () => {
  const bare = pglite(new PGlite());
  const err = await new PostgresStore(bare).verify().then(() => "started", (e) => (e as Error).message);
  assertEquals(/missing table billing_counter, table billing_window, table billing_seen/.test(err) && /schema\.sql/.test(err), true, err);
  assertEquals((await bare.unsafe(`SELECT to_regclass('billing_seen') IS NOT NULL AS there`))[0].there, false, "nothing was created");
  // A table without the state column or its constraint is named too.
  const old = pglite(new PGlite());
  for (const t of ["billing_counter (name text)", "billing_window (name text, started timestamptz)", "billing_seen (kind text, id text, expires timestamptz)"]) await old.unsafe(`CREATE TABLE ${t}`);
  const partial = await new PostgresStore(old).verify().then(() => "started", (e) => (e as Error).message);
  assertEquals(/column billing_seen\.state, constraint billing_seen_state/.test(partial), true, partial);
  await applySchema(old);
  await new PostgresStore(old).verify();
});

Deno.test("schema.sql is the add-only, idempotent script store.ts's SCHEMA says", async () => {
  assertEquals(await Deno.readTextFile(new URL("./schema.sql", import.meta.url)), schemaSql());
  assertEquals(SCHEMA.some((q) => /\bDROP\b|\bDELETE\b|\bTRUNCATE\b/i.test(q)), false, "nothing is dropped");
  assertEquals(SCHEMA.every((q) => /IF NOT EXISTS/.test(q)), true, "every statement checks first");
  const sql = schemaSql();
  assertEquals(/^SET lock_timeout = '5s';\nSET statement_timeout = '60s';$/m.test(sql), true, "the timeouts squawk requires");
  assertEquals(sql.split("\n").every((l, i, ls) => !/^CREATE INDEX/.test(l) || ls[i - 1] === "-- squawk-ignore require-concurrent-index-creation"), true, "each index says why it is not concurrent");
});

// The claim lifecycle as data, for each store: a step is [what is done, what it answers]. A claim is named
// (`a`, `b`) so a later step can use its token; `expire` ends the lease; `retention` is the ttl a completion keeps.
type Step =
  | ["claim", string, "claimed" | "busy" | "done"]
  | ["expire"]
  | ["complete", string, boolean]
  | ["forget", string]
  | ["release", string]
  | ["invalidate"]
  | ["remember"];
const lifecycle: [string, Step[]][] = [
  ["a claim is busy to another, then done once completed", [["claim", "a", "claimed"], ["claim", "x", "busy"], ["complete", "a", true], ["claim", "x", "done"]]],
  ["a lease that ended is claimable again", [["claim", "a", "claimed"], ["expire"], ["claim", "b", "claimed"]]],
  ["a stale token completes nothing and the new claim holds", [["claim", "a", "claimed"], ["expire"], ["claim", "b", "claimed"], ["complete", "a", false], ["claim", "x", "busy"], ["complete", "b", true], ["claim", "x", "done"]]],
  ["a completed claim cannot complete twice", [["claim", "a", "claimed"], ["complete", "a", true], ["complete", "a", false], ["claim", "x", "done"]]],
  ["a forgotten claim cannot be completed", [["claim", "a", "claimed"], ["forget", "a"], ["complete", "a", false], ["claim", "b", "claimed"]]],
  ["a holder releases its claim; a stale or no longer live one releases nothing", [["claim", "a", "claimed"], ["expire"], ["claim", "b", "claimed"], ["release", "a"], ["claim", "x", "busy"], ["release", "b"], ["claim", "c", "claimed"]]],
  ["a lease that ended completes nothing until it is claimed again", [["claim", "a", "claimed"], ["expire"], ["complete", "a", false], ["claim", "b", "claimed"], ["complete", "b", true]]],
  ["done is terminal: not claimable, not releasable", [["claim", "a", "claimed"], ["complete", "a", true], ["release", "a"], ["claim", "x", "done"]]],
  ["an invalidation never drops a claim in progress", [["claim", "a", "claimed"], ["invalidate"], ["claim", "x", "busy"], ["complete", "a", true]]],
  ["an invalidation drops a finished row, which is claimable again", [["claim", "a", "claimed"], ["complete", "a", true], ["invalidate"], ["claim", "b", "claimed"]]],
  ["a non-holder's release is refused and leaves the claim", [["claim", "a", "claimed"], ["release", "nobody"], ["claim", "x", "busy"], ["complete", "a", true]]],
  ["a remembered event is done, whatever claimed it", [["claim", "a", "claimed"], ["remember"], ["claim", "x", "done"], ["complete", "a", false]]],
];
for (const [name, make] of claimable) {
  for (const [what, steps] of lifecycle) {
    Deno.test(`${name} store, claim lifecycle: ${what}`, async () => {
      const { s, expire } = await make();
      const tokens = new Map<string, string>();
      for (const step of steps) {
        const label = `${what} / ${JSON.stringify(step)}`;
        if (step[0] === "claim") {
          const c = await s.claim("stripe event", "evt", 120_000);
          assertEquals(c.state, step[2], label);
          if (c.state === "claimed") tokens.set(step[1], c.token);
        } else if (step[0] === "expire") await expire("stripe event", "evt");
        else if (step[0] === "complete") assertEquals(await s.complete("stripe event", "evt", tokens.get(step[1])!, 60_000), step[2], label);
        else if (step[0] === "invalidate") await s.forget("stripe event", "evt");
        else if (step[0] === "forget" || step[0] === "release") await s.forget("stripe event", "evt", tokens.get(step[1]) ?? "not a token");
        else await s.remember("stripe event", "evt", 60_000);
      }
    });
  }
}

Deno.test("postgres store: the state column only takes the declared states, and the constraint is made once", async () => {
  const sql = pglite(new PGlite());
  await applySchema(sql);
  await applySchema(sql);
  await sql.unsafe(`INSERT INTO billing_seen (kind, id, expires, state) VALUES ('k', 'ok', now(), 'claimed')`);
  const bad = await sql.unsafe(`INSERT INTO billing_seen (kind, id, expires, state) VALUES ('k', 'bad', now(), 'busy')`).then(() => "accepted", (e) => String((e as Error).message));
  assertEquals(/billing_seen_state/.test(bad), true, `refused by the constraint: ${bad}`);
  // A table that #431 made, with the column and no constraint, gets it; its rows pass.
  const old = pglite(new PGlite());
  await old.unsafe(`CREATE TABLE billing_seen (kind text NOT NULL, id text NOT NULL, expires timestamptz NOT NULL, state text NOT NULL DEFAULT 'done', PRIMARY KEY (kind, id))`);
  await old.unsafe(`INSERT INTO billing_seen (kind, id, expires, state) VALUES ('k', 'a', now(), 'claimed')`);
  await applySchema(old);
  const refused = await old.unsafe(`INSERT INTO billing_seen (kind, id, expires, state) VALUES ('k', 'b', now(), 'x')`).then(() => "accepted", () => "refused");
  assertEquals(refused, "refused");
});

// The transition contract: every sequence of up to `depth` operations, run on each store and on the
// declaration itself (`step`), must answer alike. The model keeps only what rules.cue declares: a state, whether its
// time ended, and which token is current.
type Op = "claim" | "complete-holder" | "complete-stale" | "release-holder" | "release-stale" | "remember" | "expire" | "invalidate";
const OPS: Op[] = ["claim", "complete-holder", "complete-stale", "release-holder", "release-stale", "remember", "expire", "invalidate"];
function sequences(depth: number): Op[][] {
  let out: Op[][] = [[]];
  for (let d = 0; d < depth; d++) out = out.flatMap((q) => OPS.map((o) => [...q, o]));
  return out;
}
for (const [name, make] of claimable) {
  Deno.test(`${name} store: every sequence of claim, completion, release, remember and expiry follows rules.cue's transitions`, async () => {
    const { s, expire } = await make();
    const depth = name === "memory" ? 3 : 3;
    let n = 0;
    for (const seq of sequences(depth)) {
      const id = `seq-${n++}`;
      let where = "absent" as "absent" | "claimed" | "done", token = 0, held: string | null = null, issued = 0;
      for (const op of seq) {
        const label = `${id} ${seq.join(",")} at ${op}`;
        if (op === "claim") {
          const want = step("claim", where, false);
          const got = await s.claim("stripe event", id, 120_000);
          if (want === null) assertEquals(got.state, where === "done" ? "done" : "busy", label);
          else {
            assertEquals(got.state, "claimed", label);
            held = (got as { token: string }).token;
            token = ++issued;
            where = want as typeof where;
          }
        } else if (op === "complete-holder" || op === "complete-stale") {
          const mine = op === "complete-holder" && held !== null;
          const want = step("complete", where, mine);
          const got = await s.complete("stripe event", id, mine ? held! : "stale", 60_000);
          assertEquals(got, want !== null, label);
          if (want !== null) where = want as typeof where;
        } else if (op === "release-holder" || op === "release-stale") {
          const mine = op === "release-holder" && held !== null;
          const want = step("release", where, mine);
          await s.forget("stripe event", id, mine ? held! : "stale");
          if (want !== null) where = want as typeof where;
        } else if (op === "invalidate") {
          const want = step("invalidate", where, false);
          await s.forget("stripe event", id);
          if (want !== null) where = want as typeof where;
        } else if (op === "remember") {
          await s.remember("stripe event", id, 600_000);
          where = step("remember", where, false) as typeof where;
        } else {
          await expire("stripe event", id);
          if (where !== "absent") where = step("expire", where, false) as typeof where;
        }
      }
      void token;
    }
  });
}

Deno.test("rules.cue's transitions leave no state without a way in and name every event the stores use", () => {
  const states = new Set<string>(RULES.claimStates);
  for (const t of RULES.claimTransitions) {
    assertEquals([t.from === "absent" || states.has(t.from), t.to === "absent" || states.has(t.to)], [true, true], JSON.stringify(t));
  }
  for (const to of RULES.claimStates) assertEquals(RULES.claimTransitions.some((t) => t.to === to), true, `${to} is reached`);
  assertEquals(RULES.claimTransitions.filter((t) => t.from === "done").map((t) => t.event).sort(), ["expire", "invalidate", "remember"], "done is terminal: only its expiry, an invalidation or a remember touch it");
  assertEquals((RULES.claimTransitions as readonly { event: string; from: string }[]).some((t) => t.event === "invalidate" && t.from === "claimed"), false, "an invalidation never touches a claim in progress");
  assertEquals(RULES.claimSweep, 100, "the sweep limit is rules.cue's");
  assertEquals(target("claim", "absent"), "claimed");
  assertEquals(target("complete", "claimed"), "done");
  assertEquals(step("complete", "claimed", false), null, "completion needs the holder's token");
  assertEquals(step("claim", "claimed", false), null, "a live claim is not claimable");
});

Deno.test("expired rows are reclaimed on the claim path, a bounded few a call", async () => {
  // Memory: a clock that moves past every lease; each claim drops at most 100 of the expired.
  let t = 1_000;
  const m = new MemoryStore(() => t);
  for (let i = 0; i < 250; i++) await m.claim("stripe event", `old-${i}`, 10);
  t += 1_000;
  await m.claim("stripe event", "fresh-1", 10);
  const left = async () => { let n = 0; for (let i = 0; i < 250; i++) if (await m.seen("stripe event", `old-${i}`)) n++; return n; };
  assertEquals(await left(), 0, "expired rows are never seen");
  // Postgres: the rows themselves go, a bounded few a claim.
  const sql = pglite(new PGlite());
  await applySchema(sql);
  const p = new PostgresStore(sql);
  for (let i = 0; i < 150; i++) await sql.unsafe(`INSERT INTO billing_seen (kind, id, expires, state) VALUES ('stripe event', $1, now() - interval '1 hour', 'done')`, [`old-${i}`]);
  await p.claim("stripe event", "fresh", 120_000);
  const [{ n }] = await sql.unsafe(`SELECT count(*)::int AS n FROM billing_seen`);
  assertEquals(n, 150 - 100 + 1, "one claim reclaims at most 100 expired rows");
});

Deno.test("postgres store: the durable counter is the authority, across a restart, replicas and a slow clock", async () => {
  const sql = pglite(new PGlite());
  await applySchema(sql);
  const a = new PostgresStore(sql);
  const issued = [await a.tick("ver", 5_000_000), await a.tick("ver", 5_000_000)];
  // A restart: a new store on the same database, whose clock is far behind what was issued.
  const b = new PostgresStore(sql);
  const after = [await b.tick("ver", 1_000), await a.tick("ver", 2_000), await b.tick("ver", 0)];
  assertEquals([...issued, ...after].every((v, i, all) => i === 0 || v > all[i - 1]), true, `never backward: ${[...issued, ...after]}`);
  // A clock ahead moves the counter forward, recorded: a slow replica after it cannot go back.
  const ahead = await a.tick("ver", 9_000_000);
  assertEquals(ahead, 9_000_000);
  assertEquals(await b.tick("ver", 1), 9_000_001, "recorded in the database, not in a replica's clock");
});

Deno.test("memory store: a sweep continues where it stopped and drops the declared expiry's rows, a bounded few a call", async () => {
  let t = 1_000;
  const m = new MemoryStore(() => t);
  for (let i = 0; i < 250; i++) await m.claim("stripe event", `old-${i}`, 10);
  t += 1_000;
  // Each call looks at most claimSweep rows, from where the last stopped, so a few calls clear them all and none
  // looks at the same hundred twice.
  const sizes: number[] = [250];
  for (let i = 0; i < 4; i++) {
    await m.claim("stripe event", `fresh-${i}`, 120_000);
    sizes.push(m.rows);
  }
  // A call adds its own row and sweeps at most claimSweep expired ones.
  assertEquals(sizes.every((n, i) => i === 0 || sizes[i - 1] + 1 - n <= 100), true, `bounded: ${sizes}`);
  assertEquals(sizes.at(-1), 4, `every expired row went, only the four live claims stay: ${sizes}`);
});

// Two replicas on one database: every write is one conditional statement, so a conflicting write changes nothing
// and says so. (PGlite has one connection; the two stores interleave their statements on it, as two pods' would.)
Deno.test("postgres store, two replicas: takeover, completion, release and expiry conflict without overwriting", async () => {
  const sql = pglite(new PGlite());
  await applySchema(sql);
  const a = new PostgresStore(sql), b = new PostgresStore(sql);
  const expire = (id: string) => sql.unsafe(`UPDATE billing_seen SET expires = now() - interval '1 second' WHERE kind = 'stripe event' AND id = $1`, [id]);
  const state = async (id: string) => (await sql.unsafe(`SELECT state FROM billing_seen WHERE kind = 'stripe event' AND id = $1`, [id]))[0]?.state ?? "absent";

  // Takeover vs completion: A's lease ends, B takes over, A's late completion changes nothing; B's lands.
  const first = await a.claim("stripe event", "t1", 120_000) as { token: string };
  await expire("t1");
  await sleep(5);
  const second = await b.claim("stripe event", "t1", 120_000) as { token: string };
  assertEquals(await a.complete("stripe event", "t1", first.token, 60_000), false, "the stale holder's completion affects no row");
  assertEquals(await state("t1"), "claimed", "B's claim stands");
  assertEquals(await b.complete("stripe event", "t1", second.token, 60_000), true);
  assertEquals(await a.complete("stripe event", "t1", first.token, 60_000), false, "and a finished row takes no second completion");

  // Release vs completion: the holder completes, then a late release (its own or another's) deletes nothing.
  const c = await a.claim("stripe event", "t2", 120_000) as { token: string };
  assertEquals(await b.forget("stripe event", "t2", "not the token"), false, "a non-holder's release is refused");
  assertEquals(await a.complete("stripe event", "t2", c.token, 60_000), true);
  assertEquals(await a.forget("stripe event", "t2", c.token), false, "release after completion deletes nothing");
  assertEquals(await state("t2"), "done");
  // And the other order: released first, then the completion finds no claim.
  const d = await a.claim("stripe event", "t3", 120_000) as { token: string };
  assertEquals(await a.forget("stripe event", "t3", d.token), true);
  assertEquals(await b.complete("stripe event", "t3", d.token, 60_000), false, "completion after release affects no row");

  // Expiry vs completion: the lease ended before the completion arrived; it is refused, never revived.
  const e = await a.claim("stripe event", "t4", 120_000) as { token: string };
  await expire("t4");
  assertEquals(await b.complete("stripe event", "t4", e.token, 60_000), false, "an expired claim completes nothing");
  assertEquals(await state("t4"), "claimed", "the row is untouched by the refused write");
  // An invalidation never takes a claim in progress, whichever replica asks.
  await a.claim("stripe event", "t5", 120_000);
  assertEquals(await b.forget("stripe event", "t5"), false, "invalidate refuses a claim in progress");
  assertEquals(await state("t5"), "claimed");
});

// One data case for both stores: by the declared transitions an expired row is absent, so invalidating it is refused
// (false) and a live finished row is invalidated (true), whichever store keeps it.
for (const [name, make] of claimable) {
  Deno.test(`${name} store: an invalidation of an expired, unswept done row is refused; of a live one it lands`, async () => {
    const { s, expire } = await make();
    const c = await s.claim("stripe event", "live", 120_000) as { token: string };
    await s.complete("stripe event", "live", c.token, 600_000);
    assertEquals(await s.forget("stripe event", "live"), true, "a live finished row is dropped");
    const d = await s.claim("stripe event", "old", 120_000) as { token: string };
    await s.complete("stripe event", "old", d.token, 600_000);
    await expire("stripe event", "old");
    assertEquals(await s.forget("stripe event", "old"), false, "an expired row is absent: nothing to invalidate");
    assertEquals(step("invalidate", "absent", false), null, "which is the declaration's word for it");
  });
}
