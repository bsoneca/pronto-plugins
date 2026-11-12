// The broker's store (store.ts): the memory one and the Postgres one (its SQL run on PGlite, which is
// Postgres compiled to WASM, so no server is needed) hold to the same cases; the Postgres client's wire
// protocol is postgres.js's and is not tested here. Then the broker's state on two replicas sharing one
// store, each a handler of its own, as two pods would be: a code made by one is redeemed by the other,
// wrong guesses are counted across them, and both serve the same keys.
import { PGlite } from "npm:@electric-sql/pglite@0.3.7";
import { jwkThumbprint } from "../oidc.ts";
import { MemoryStore, PostgresStore, SCHEMA, SQL, type Sql, type Store, sealedOnce, sharedKeyPair } from "./store.ts";
import { Otp } from "./otp.ts";
import { phoneConfig, phoneUpstream } from "./phone.ts";
import { broker } from "./main.ts";

function assertEquals(a: unknown, b: unknown, m = "") {
  if (JSON.stringify(a) !== JSON.stringify(b)) throw new Error(`${m} expected ${JSON.stringify(b)}, got ${JSON.stringify(a)}`);
}
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

/** PGlite as the one method the store uses of postgres.js. */
function pglite(pg: PGlite): Sql {
  return {
    unsafe: async (q, params) => (await pg.query(q, params ?? [])).rows as Record<string, unknown>[],
  };
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
  Deno.test(`${name} store: a value is held until it expires, and taken once`, async () => {
    const s = await make();
    await s.put("code", "c1", { sub: "p" }, 60_000);
    assertEquals(await s.get("code", "c1"), { sub: "p" });
    assertEquals(await s.get("other", "c1"), undefined, "kinds are apart");
    assertEquals(await s.take("code", "c1"), { sub: "p" });
    assertEquals(await s.take("code", "c1"), undefined, "single use");
    assertEquals(await s.get("code", "c1"), undefined);
    await s.put("code", "c2", 1, 20);
    await sleep(60);
    assertEquals([await s.get("code", "c2"), await s.take("code", "c2")], [undefined, undefined], "expired");
    // Two takes at once: one gets it.
    await s.put("code", "c3", "x", 60_000);
    const both = await Promise.all([s.take("code", "c3"), s.take("code", "c3")]);
    assertEquals(both.filter((v) => v !== undefined).length, 1);
  });

  Deno.test(`${name} store: wrong guesses are counted against a held value and reset by a new one`, async () => {
    const s = await make();
    assertEquals(await s.bump("otp", "v"), undefined, "nothing held");
    await s.put("otp", "v", 1, 60_000);
    assertEquals([await s.bump("otp", "v"), await s.bump("otp", "v")], [1, 2]);
    await s.put("otp", "v", 2, 60_000);
    assertEquals(await s.bump("otp", "v"), 1);
    // Concurrent bumps never share a count.
    const counts = await Promise.all([s.bump("otp", "v"), s.bump("otp", "v"), s.bump("otp", "v")]);
    assertEquals(counts.sort(), [2, 3, 4]);
  });

  Deno.test(`${name} store: a claim is held by one caller until it lapses`, async () => {
    const s = await make();
    const won = await Promise.all([s.claim("next", "+55", 40), s.claim("next", "+55", 40)]);
    assertEquals(won.filter(Boolean).length, 1);
    const left = await s.left("next", "+55");
    assertEquals(left > 0 && left <= 40, true, `left ${left}`);
    assertEquals(await s.claim("next", "+55", 40), false);
    await sleep(80);
    assertEquals([await s.left("next", "+55"), await s.claim("next", "+55", 40)], [0, true], "free again once it lapsed");
    await s.del("next", "+55");
    assertEquals(await s.claim("next", "+55", 40), true, "freed by a delete");
  });

  Deno.test(`${name} store: a value made once is the first one made`, async () => {
    const s = await make();
    const got = await Promise.all([s.once("k", () => "first"), s.once("k", () => "second")]);
    assertEquals(got[0], got[1]);
    assertEquals(await s.once("k", () => "third"), got[0]);
    assertEquals(await s.once("other", () => "own"), "own");
  });
}

Deno.test("two stores on one database share what is in it", async () => {
  const sql = pglite(new PGlite());
  const a = new PostgresStore(sql), b = new PostgresStore(sql);
  await a.migrate();
  await a.put("code", "c", "grant", 60_000);
  assertEquals(await b.take("code", "c"), "grant");
  assertEquals(await a.take("code", "c"), undefined);
  assertEquals(await a.once("key", () => "a's"), await b.once("key", () => "b's"));
});

Deno.test("the store's statements are the ones that make the operations atomic", async () => {
  const seen: [string, unknown[] | undefined][] = [];
  const s = new PostgresStore({ unsafe: (q, p) => { seen.push([q, p]); return Promise.resolve([]); } });
  await s.take("code", "c");
  await s.claim("next", "+55", 60_000);
  await s.bump("otp", "v");
  await s.put("code", "c", { a: 1 }, 5000);
  const sql = seen.map(([q]) => q.replace(/\s+/g, " "));
  assertEquals(sql[0], SQL.take.replace(/\s+/g, " "));
  assertEquals(/^DELETE FROM broker_kv .*expires > now\(\) RETURNING value$/.test(sql[0]), true, "take deletes and returns in one statement, live rows only");
  assertEquals(/ON CONFLICT \(kind, key\) DO UPDATE .* WHERE broker_kv\.expires <= now\(\) RETURNING/.test(sql[1]), true, "claim wins only over a lapsed row");
  assertEquals(/^UPDATE broker_kv SET tries = tries \+ 1 .* RETURNING tries$/.test(sql[2]), true, "a wrong guess is counted in the database");
  assertEquals(/^DELETE FROM broker_kv WHERE ctid IN \(SELECT ctid .* LIMIT \d+\)$/.test(sql[3]), true, "a put first sweeps a bounded few expired rows");
  assertEquals(seen[4][1], ["code", "c", '{"a":1}', 5000]);
  assertEquals(SCHEMA.every((q) => /^CREATE (TABLE|INDEX) IF NOT EXISTS/.test(q)), true, "tables made idempotently");
});

Deno.test("a signing key is made once and every replica serves it, its kid its thumbprint", async () => {
  const store = new MemoryStore();
  const [a, b] = await Promise.all([sharedKeyPair(store, "k", "ES256"), sharedKeyPair(store, "k", "ES256")]);
  assertEquals(a.jwk, b.jwk);
  assertEquals(a.jwk.kid, await jwkThumbprint({ kty: "EC", crv: "P-256", x: a.jwk.x, y: a.jwk.y }));
  assertEquals((a.jwk as { d?: string }).d, undefined, "the public half only");
  const sig = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, b.privateKey, new Uint8Array([1]));
  const pub = await crypto.subtle.importKey("jwk", a.jwk, { name: "ECDSA", namedCurve: "P-256" }, false, ["verify"]);
  assertEquals(await crypto.subtle.verify({ name: "ECDSA", hash: "SHA-256" }, pub, sig, new Uint8Array([1])), true, "what one signs, the other's served key verifies");
  const other = await sharedKeyPair(new MemoryStore(), "k", "ES256");
  assertEquals(other.jwk.kid === a.jwk.kid, false, "another key is another kid");
});

Deno.test("the thumbprint is RFC 7638's (its own example)", async () => {
  const jwk = {
    kty: "RSA", e: "AQAB",
    n: "0vx7agoebGcQSuuPiLJXZptN9nndrQmbXEps2aiAFbWhM78LhWx4cbbfAAtVT86zwu1RK7aPFFxuhDR1L6tSoc_BJECPebWKRXjBZCiFV4n3oknjhMstn64tZ_2W-5JsGY4Hc5n9yBXArwl93lqt7_RN5w6Cf0h4QyQ5v-65YGjQR0_FDW2QvzqY368QQMicAtaSqzs8KJZgnYb9c7d0zgdAZHzu6qMQvRL5hajrn1n91CbOpbISD08qNLyrdkt-bFTWhAI4vMQFh6WeZu0fM4lFd2NcRwr3XPksINHaQ-G_xBniIqbw0Ls1jF44-csFCur-kEgU8awapJzKnqDKgw",
  };
  assertEquals(await jwkThumbprint(jwk), "NzbLsXh8uDCcd-6MNwXF4W_7noWXFZAfHkxZsRGC9Xs");
});

// --- Two replicas of the broker over one store ---

const ISSUER = "https://id.example.com";
const SECRET = "s".repeat(40);
const PHONE_ENV: Record<string, string> = {
  PHONE_OTP: "broker", PHONE_SMS: "standin", PHONE_SMS_GATE: "https://app.example.com/rental/phone/sms-gate",
  PHONE_ADMIT: "https://app.example.com/rental/phone/admit", PHONE_TENANTS: "https://app.example.com",
};
const TENANT = "https://app.example.com";

/** One replica: the phone and the broker around it, the store shared, the SMS captured in `texts`. */
async function replica(store: Store, texts: string[]) {
  const cfg = phoneConfig((k) => PHONE_ENV[k], "http://localhost:19000")!;
  cfg.sender = { send: (_to, text) => { texts.push(text); return Promise.resolve(); } };
  const up = await phoneUpstream(ISSUER, cfg, { secret: SECRET, store, fetcher: () => Promise.resolve(new Response("{}")) });
  const handle = await broker({ issuer: ISSUER, secret: SECRET, providers: [up.provider], extra: up.handle, store });
  return { up, handle };
}

const post = (h: (r: Request) => Promise<Response>, path: string, body: unknown) =>
  h(new Request(`${ISSUER}${path}`, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(body) }));

Deno.test("phone sign-in across two replicas: one visit, one count of wrong guesses, one set of keys", async () => {
  const store = new MemoryStore();
  const texts: string[] = [];
  const a = await replica(store, texts), b = await replica(store, texts);
  const visit = async () => {
    const q = new URLSearchParams({ client_id: "phone", redirect_uri: `${ISSUER}/callback/phone`, state: "S1", nonce: "N1" });
    const page = await (await a.handle(new Request(`${ISSUER}/phone/auth?${q}`, { headers: { "accept-language": "pt-BR" } }))).text();
    return JSON.parse(/<script type="application\/json" id="phone-config">([^<]*)<\/script>/.exec(page)![1]).id as string;
  };
  const phone = "+5511912345678";

  // The visit begun on A is known to B: B sends the code, and only one SMS goes inside the wait.
  const id = await visit();
  assertEquals((await post(b.handle, "/phone/send", { id, phone })).status, 200);
  assertEquals((await post(a.handle, "/phone/send", { id, phone })).status, 429, "the wait holds across replicas");
  assertEquals(texts.length, 1);
  const right = /\b[0-9]{6}\b/.exec(texts[0])![0];

  // Wrong guesses are counted once across them: the fifth, on whichever replica, is the last.
  const wrong = right === "000000" ? "111111" : "000000";
  const said = [];
  for (const h of [a, b, a, b, a]) said.push((await (await post(h.handle, "/phone/approve", { id, code: wrong })).json()).error);
  assertEquals(said, ["wrong_code", "wrong_code", "wrong_code", "wrong_code", "too_many"]);
  assertEquals((await (await post(b.handle, "/phone/approve", { id, code: right })).json()).error, "expired", "a dead code stays dead on the other replica");

  // A fresh visit: approved on A, its code redeemed on B, and only once.
  const id2 = await visit();
  await store.del("otp-next", phone); // past the resend wait
  assertEquals((await post(a.handle, "/phone/send", { id: id2, phone })).status, 200);
  const code2 = /\b[0-9]{6}\b/.exec(texts[1])![0];
  const approved = await (await post(a.handle, "/phone/approve", { id: id2, code: code2 })).json();
  const bridge = new URL(approved.to).searchParams.get("code")!;
  const exchange = (h: typeof a.handle, secret: string) => h(new Request(`${ISSUER}/phone/token`, {
    method: "POST", headers: { "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({ grant_type: "authorization_code", code: bridge, client_id: "phone", client_secret: secret, redirect_uri: `${ISSUER}/callback/phone` }),
  }));
  assertEquals(a.up.provider.clientSecret, b.up.provider.clientSecret, "one client secret");
  assertEquals((await exchange(b.handle, a.up.provider.clientSecret!)).status, 200, "redeemed by the other replica");
  assertEquals((await exchange(a.handle, a.up.provider.clientSecret!)).status, 400, "and once");

  // One key: the same JWK at both, its kid the public key's thumbprint, RS256.
  const jwks = async (h: typeof a.handle) => (await (await h(new Request(`${ISSUER}/phone/jwks`))).json()).keys;
  const [ka, kb] = [await jwks(a.handle), await jwks(b.handle)];
  assertEquals(ka, kb);
  assertEquals([ka[0].alg, ka[0].kid], ["RS256", await jwkThumbprint({ kty: "RSA", n: ka[0].n, e: ka[0].e })]);
});

Deno.test("an OTP's wrong guesses and resend wait are shared by Otp instances over one store", async () => {
  const store = new MemoryStore();
  const x = new Otp(60, store), y = new Otp(60, store);
  const made = await x.issue("v", "+55");
  assertEquals("code" in made, true);
  assertEquals("wait" in await y.issue("w", "+55"), true, "one text per number inside the wait");
  const code = (made as { code: string }).code;
  assertEquals((await y.check("v", code)).result, "ok", "a code made by one is checked by the other");
  assertEquals((await x.check("v", code)).result, "expired", "and spent once");
  await x.revoke("v");
});

Deno.test("two broker replicas serve one ID-token key", async () => {
  const store = new MemoryStore();
  const h = [await broker({ issuer: ISSUER, secret: SECRET, providers: [], store }), await broker({ issuer: ISSUER, secret: SECRET, providers: [], store })];
  const [x, y] = await Promise.all(h.map(async (f) => await (await f(new Request(`${ISSUER}/jwks`))).json()));
  assertEquals(x, y);
  assertEquals(x.keys[0].kid, await jwkThumbprint({ kty: "EC", crv: "P-256", x: x.keys[0].x, y: x.keys[0].y }));
});

Deno.test("the keys and secrets made once are sealed under BROKER_SECRET, and open only under it", async () => {
  const held = new MemoryStore();
  const secret = "s".repeat(32);
  const a = await sealedOnce(held, secret);
  const b = await sealedOnce(held, secret);
  const { jwk } = await sharedKeyPair(a, "k", "ES256");
  assertEquals((await sharedKeyPair(b, "k", "ES256")).jwk, jwk, "a second replica opens the same key");
  const raw = await held.once("k", () => "unused");
  if (!raw.startsWith("v1.") || raw.includes('"d"')) throw new Error(`held in the clear: ${raw.slice(0, 40)}`);
  const other = await sealedOnce(held, "t".repeat(32));
  const refused = await other.once("k", () => "unused").then(() => "", (e: Error) => e.message);
  if (!refused.includes("another BROKER_SECRET")) throw new Error(`opened under another secret: ${refused}`);
});
