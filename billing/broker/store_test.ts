// The billing broker's store (store.ts): the memory one and the Postgres one (its SQL run on PGlite,
// Postgres compiled to WASM, so no server is needed) hold to the same cases, as the identity broker's
// store tests do. PGlite has one connection, so two Postgres locks at once are shown by the statements
// that take them (an advisory lock held by a transaction); the memory store shows the waiting itself.
import { PGlite } from "npm:@electric-sql/pglite@0.3.7";
import { MemoryStore, PostgresStore, SQL, type Sql, type Store } from "./store.ts";

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

const stores: [string, () => Promise<Store>][] = [
  ["memory", () => Promise.resolve(new MemoryStore())],
  ["postgres", async () => {
    const s = new PostgresStore(pglite(new PGlite()));
    await s.migrate();
    await s.migrate(); // idempotent: a second start finds the tables there
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
  await a.migrate();
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
