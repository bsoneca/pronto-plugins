// The App Store as a source of entitlements (appstore.ts, main.ts), against a chain of the test's own standing in for Apple's, a
// stand-in for Apple's Server API, and two tenants this test serves. The payloads are shaped as Apple documents them
// (appstore_fixture.ts); none of it is Apple's, so none of it holds a real key.
import { brokerKeys, type Entitlement, verifyEntitlement } from "../entitlement.ts";
import { Refused } from "../shared.ts";
import { fakeStripe } from "./fake.ts";
import { bodyLimitOf, endpointRefusal, stripe as stripeClient, withCappedBody } from "./stripe.ts";
import { broker } from "./main.ts";
import { type AppStoreConfig, appstoreConfigFrom, checkSandboxApps, heldOf, importApiKey, merged, verifySigned } from "./appstore.ts";
import { MemoryStore } from "./store.ts";
import { apiKeyPem, type Chain, makeChain, notification, transaction } from "./appstore_fixture.ts";

function assertEquals(a: unknown, b: unknown, m = "") {
  if (JSON.stringify(a) !== JSON.stringify(b)) throw new Error(`${m} expected ${JSON.stringify(b)}, got ${JSON.stringify(a)}`);
}

const ISSUER = "http://localhost:28463";
const A = "https://a.example", B = "https://b.example";
const ANA = "00000000-0000-4000-8000-00000000000a";
const BEA = "00000000-0000-4000-8000-00000000000b";
const BUNDLE = "com.example.chess", OTHER_BUNDLE = "com.example.other";
const PREMIUM = "com.example.chess.premium.monthly", GOLD = "com.example.chess.gold.100";
const DAY = 86_400_000;

const chain = await makeChain();
const rogue = await makeChain();
const key = await apiKeyPem();

interface Held { status: number; tx: Record<string, unknown>; renewal?: Record<string, unknown>; renewalSigner?: Chain }

async function setup(o: { sandbox?: boolean; off?: boolean } = {}) {
  const config: AppStoreConfig = {
    apps: [{ bundleId: BUNDLE, tenant: A, products: { [PREMIUM]: "analysis" }, sandbox: o.sandbox === true }, { bundleId: OTHER_BUNDLE, tenant: B, products: { [PREMIUM]: "analysis" }, sandbox: false }],
    roots: [chain.rootPem], issuerId: "11111111-2222-3333-4444-555555555555", keyId: "TESTKEY123", key: await importApiKey(key),
  };
  // What Apple's Server API answers for a subscription, by its original transaction id, and what it was asked with.
  const apple = { held: new Map<string, Held[]>(), calls: [] as { host: string; id: string; jwt: Record<string, unknown>; head: Record<string, unknown> }[], down: 0 };
  const tenants = new Map<string, { got: Entitlement[]; refuse?: boolean }>([[A, { got: [] }], [B, { got: [] }]]);
  const fake = fakeStripe(ISSUER);
  const door = stripeClient({ door: `${ISSUER}/door/stripe`, fetcher: ((u: string | URL | Request, init?: RequestInit) => fake.handle(new Request(u, init))!) as typeof fetch });
  const decode = (part: string) => JSON.parse(atob(part.replace(/-/g, "+").replace(/_/g, "/")));
  const fetcher = (async (input: string | URL | Request, init?: RequestInit) => {
    const url = new URL(input instanceof Request ? input.url : input);
    if (url.origin === ISSUER) return await handler(new Request(url, init));
    const host = url.host;
    if (host === "api.storekit.itunes.apple.com" || host === "api.storekit-sandbox.itunes.apple.com") {
      const jwt = String((init?.headers as Record<string, string>).authorization).replace("Bearer ", "").split(".");
      const id = decodeURIComponent(url.pathname.split("/").at(-1)!);
      apple.calls.push({ host, id, jwt: decode(jwt[1]), head: decode(jwt[0]) });
      if (apple.down) return new Response("down", { status: apple.down });
      const last = await Promise.all((apple.held.get(id) ?? []).map(async (h) => ({
        status: h.status, originalTransactionId: id, signedTransactionInfo: await chain.sign(h.tx),
        ...(h.renewal ? { signedRenewalInfo: await (h.renewalSigner ?? chain).sign(h.renewal) } : {}),
      })));
      return Response.json({ environment: host.includes("sandbox") ? "Sandbox" : "Production", bundleId: BUNDLE, data: last.length ? [{ subscriptionGroupIdentifier: "1", lastTransactions: last }] : [] });
    }
    const t = tenants.get(url.origin);
    if (!t) throw new TypeError("connection refused");
    if (url.pathname === "/billing/events") {
      try {
        const e = await verifyEntitlement(String(init?.body), { issuer: ISSUER, tenant: url.origin, keys });
        if (t.refuse) return new Response("refused", { status: 400 });
        t.got.push(e);
        return new Response(null, { status: 204 });
      } catch (e) {
        if (e instanceof Refused) return new Response(e.message, { status: 400 });
        throw e;
      }
    }
    return new Response("", { status: 404 });
  }) as typeof fetch;
  const handler = await broker({ issuer: ISSUER, secret: "s".repeat(32), stripe: door, webhookSecret: fake.webhookSecret, fetcher, cacheMs: 0, store: new MemoryStore(), ...(o.off ? {} : { appstore: config }) });
  const keys = brokerKeys(ISSUER, fetcher, 0);
  const post = (path: string, body: unknown) => handler(new Request(`${ISSUER}${path}`, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(body) }));
  const claim = async (tx: Record<string, unknown>, over: Record<string, unknown> = {}, signer: Chain = chain) =>
    post("/appstore/transaction", { tenant: A, account: ANA, transaction: await signer.sign(tx), ...over });
  const note = async (n: Record<string, unknown>, signer: Chain = chain) => post("/appstore", { signedPayload: await signer.sign(n) });
  // Apple holds a subscription: the transaction as its server answers it, and its status.
  const hold = (id: string, status: number, tx: Record<string, unknown>, extra: Partial<Held> = {}) => apple.held.set(id, [{ status, tx, ...extra }]);
  return { config, apple, tenants, post, claim, note, hold, handler, fake, keys };
}

const live = (id: string, over: Partial<Parameters<typeof transaction>[0]> = {}) => transaction({ transactionId: id, appAccountToken: ANA, ...over });

Deno.test("a player's purchase is checked, read again from Apple, and the tenant alone is told", async () => {
  const { apple, tenants, claim, hold } = await setup();
  const tx = live("2000000000000001");
  hold("2000000000000001", 1, tx);
  const res = await claim(tx);
  assertEquals(res.status, 200, await res.clone().text());
  const body = await res.json();
  assertEquals([body.ok, body.plan, body.active, body.through], [true, "analysis", true, Math.floor((tx.expiresDate as number) / 1000)]);
  const [got] = tenants.get(A)!.got;
  assertEquals([got.account, got.plan, got.active, got.through], [ANA, "analysis", true, body.through]);
  assertEquals(tenants.get(B)!.got.length, 0, "the other tenant hears nothing");
  // Apple was asked, as the operator's key, for this bundle, in production.
  const [call] = apple.calls;
  assertEquals([call.host, call.id, call.head.alg, call.head.kid, call.jwt.iss, call.jwt.aud, call.jwt.bid], [
    "api.storekit.itunes.apple.com", "2000000000000001", "ES256", "TESTKEY123", "11111111-2222-3333-4444-555555555555", "appstoreconnect-v1", BUNDLE]);
  assertEquals((call.jwt.exp as number) - (call.jwt.iat as number) <= 300, true, "a token that lives minutes");
});

Deno.test("a transaction taken once is not taken again", async () => {
  const { tenants, claim, hold } = await setup();
  const tx = live("2000000000000002");
  hold("2000000000000002", 1, tx);
  assertEquals((await claim(tx)).status, 200);
  const again = await claim(tx);
  assertEquals([again.status, (await again.json()).error], [409, "replayed"]);
  assertEquals(tenants.get(A)!.got.length, 1, "no second entitlement");
});

Deno.test("a client's claim is only a pointer: what Apple does not confirm holds nothing, and may be tried again", async () => {
  const { tenants, claim, hold, apple } = await setup();
  const tx = live("2000000000000003");
  hold("2000000000000003", 2, tx); // Apple: expired
  const res = await claim(tx);
  assertEquals([res.status, (await res.json()).error], [409, "not active at the App Store"]);
  assertEquals(tenants.get(A)!.got.every((e) => !e.active), true, "nothing active was pushed");
  hold("2000000000000003", 1, tx);
  assertEquals((await claim(tx)).status, 200, "the claim was given back, not spent");
  assertEquals(apple.calls.length, 2);
  // Apple knowing nothing of it (a claim for a subscription it has no record of) holds nothing either.
  const unknown = await claim(live("2000000000000004"));
  assertEquals(unknown.status, 409);
});

Deno.test("what is not Apple's, or not for this tenant, account or environment, is refused before Apple is asked", async () => {
  const { tenants, claim, hold, apple, post } = await setup();
  const tx = live("2000000000000005");
  hold("2000000000000005", 1, tx);
  const refused = async (label: string, res: Response, status: number, error?: string) => {
    const body = await res.json();
    assertEquals([label, res.status, error === undefined ? body.error !== undefined : body.error], [label, status, error === undefined ? true : error]);
  };
  await refused("a chain of another root", await claim(tx, {}, rogue), 403, "signed data refused: not Apple's root");
  // A payload altered after Apple signed it: the premium it claims was never bought.
  const good = await chain.sign(tx);
  const [h, , s] = good.split(".");
  const forged = `${h}.${btoa(JSON.stringify({ ...tx, expiresDate: Date.now() + 999 * DAY })).replace(/=+$/, "").replace(/\+/g, "-").replace(/\//g, "_")}.${s}`;
  await refused("a payload altered", await post("/appstore/transaction", { tenant: A, account: ANA, transaction: forged }), 403, "signed data refused: signature");
  await refused("alg none", await claim(tx, {}, { ...chain, sign: (p) => chain.sign(p, { alg: "none" }) }), 403, "signed data refused: algorithm");
  await refused("not a JWS", await post("/appstore/transaction", { tenant: A, account: ANA, transaction: "a.b" }), 400);
  await refused("no transaction", await post("/appstore/transaction", { tenant: A, account: ANA }), 400);
  await refused("another bundle", await claim(live("2000000000000006", { bundleId: "com.attacker.app" })), 403, "bundle refused");
  await refused("a bundle of another tenant", await claim(live("2000000000000007", { bundleId: OTHER_BUNDLE })), 403, "bundle refused");
  await refused("a sandbox purchase at a live app", await claim(live("2000000000000008", { environment: "Sandbox" })), 403, "environment refused");
  await refused("a local StoreKit test", await claim(live("2000000000000009", { environment: "Xcode" })), 403, "environment refused");
  await refused("a product that is no plan", await claim(live("2000000000000010", { productId: GOLD })), 400, "product refused");
  await refused("another account's purchase", await claim(live("2000000000000011", { appAccountToken: BEA })), 403, "the transaction is another account's");
  await refused("a purchase with no account named", await claim(live("2000000000000012", { appAccountToken: null })), 403, "the transaction is another account's");
  await refused("a revoked one", await claim(live("2000000000000013", { revocationDate: Date.now() - 1000 })), 409, "revoked");
  await refused("an expired one", await claim(live("2000000000000014", { expiresDate: Date.now() - 1000 })), 409, "expired");
  await refused("a tenant that is not the bundle's", await claim(tx, { tenant: B }), 403, "bundle refused");
  assertEquals([apple.calls.length, tenants.get(A)!.got.length, tenants.get(B)!.got.length], [0, 0, 0], "nothing asked of Apple, nothing pushed");
});

Deno.test("a sandbox app counts sandbox purchases, and asks Apple's sandbox", async () => {
  const { apple, tenants, claim, hold } = await setup({ sandbox: true });
  const tx = live("2000000000000020", { environment: "Sandbox" });
  hold("2000000000000020", 1, tx);
  assertEquals((await claim(tx)).status, 200);
  assertEquals(apple.calls[0].host, "api.storekit-sandbox.itunes.apple.com");
  assertEquals(tenants.get(A)!.got.length, 1);
});

Deno.test("Apple's notifications renew, expire, refund and revoke, each read again from Apple", async () => {
  const { tenants, claim, note, hold } = await setup();
  const got = () => tenants.get(A)!.got;
  const first = live("2000000000000030", { expiresDate: Date.now() + 30 * DAY });
  hold("2000000000000030", 1, first);
  assertEquals((await claim(first)).status, 200);
  assertEquals([got().length, got().at(-1)!.active], [1, true]);
  // A renewal: the subscription now runs a month longer.
  const renewed = live("2000000000000031", { originalTransactionId: "2000000000000030", expiresDate: Date.now() + 60 * DAY });
  hold("2000000000000030", 1, renewed);
  let res = await note(notification({ type: "DID_RENEW", uuid: "n-renew", signedTransactionInfo: await chain.sign(renewed) }));
  assertEquals([res.status, (await res.json()).delivered], [200, "n-renew"]);
  assertEquals([got().length, got().at(-1)!.active, got().at(-1)!.through], [2, true, Math.floor((renewed.expiresDate as number) / 1000)]);
  // Apple sends it again (it does until it is answered): taken once.
  res = await note(notification({ type: "DID_RENEW", uuid: "n-renew", signedTransactionInfo: await chain.sign(renewed) }));
  assertEquals([res.status, (await res.json()).duplicate], [200, "n-renew"]);
  assertEquals(got().length, 2, "a duplicate pushes nothing");
  // A refund: Apple's record of the subscription shows the transaction revoked.
  const refunded = live("2000000000000031", { originalTransactionId: "2000000000000030", expiresDate: renewed.expiresDate as number, revocationDate: Date.now() - 1000 });
  hold("2000000000000030", 5, refunded);
  res = await note(notification({ type: "REFUND", uuid: "n-refund", signedTransactionInfo: await chain.sign(refunded) }));
  assertEquals(res.status, 200);
  assertEquals([got().length, got().at(-1)!.active, got().at(-1)!.through], [3, false, 0]);
  // Restored (a refund reversed), then revoked through Family Sharing's end, then expired: each is what Apple says.
  hold("2000000000000030", 1, renewed);
  await note(notification({ type: "REFUND_REVERSED", uuid: "n-rev", signedTransactionInfo: await chain.sign(renewed) }));
  assertEquals(got().at(-1)!.active, true);
  hold("2000000000000030", 5, refunded);
  await note(notification({ type: "REVOKE", uuid: "n-revoke", signedTransactionInfo: await chain.sign(refunded) }));
  assertEquals(got().at(-1)!.active, false);
  hold("2000000000000030", 1, renewed);
  await note(notification({ type: "SUBSCRIBED", subtype: "RESUBSCRIBE", uuid: "n-sub", signedTransactionInfo: await chain.sign(renewed) }));
  hold("2000000000000030", 2, renewed);
  await note(notification({ type: "EXPIRED", subtype: "VOLUNTARY", uuid: "n-expired", signedTransactionInfo: await chain.sign(renewed) }));
  assertEquals([got().at(-1)!.active, got().at(-1)!.through], [false, 0]);
  // Each entitlement newer than the one before it.
  const vers = got().map((e) => e.ver);
  assertEquals(vers.every((v, i) => i === 0 || v > vers[i - 1]), true);
});

Deno.test("a notification is believed only as Apple's, for a bundle the operator ties to a tenant", async () => {
  const { tenants, note, hold, post } = await setup();
  const tx = live("2000000000000040");
  hold("2000000000000040", 1, tx);
  const signedTx = await chain.sign(tx);
  const body = async (r: Response) => (await r.json()).error as string;
  let res = await note(notification({ type: "DID_RENEW", uuid: "n-1", signedTransactionInfo: signedTx }), rogue);
  assertEquals([res.status, await body(res)], [403, "signed data refused: not Apple's root"]);
  res = await note(notification({ type: "DID_RENEW", uuid: "n-2", signedTransactionInfo: await rogue.sign(tx) }));
  assertEquals(res.status, 403, "a genuine envelope around a forged transaction");
  res = await note(notification({ type: "DID_RENEW", uuid: "n-3", signedTransactionInfo: signedTx, bundleId: "com.attacker.app" }));
  assertEquals([res.status, await body(res)], [403, "bundle refused"]);
  res = await note(notification({ type: "DID_RENEW", uuid: "n-4", signedTransactionInfo: signedTx, environment: "Sandbox" }));
  assertEquals([res.status, await body(res)], [403, "environment refused"]);
  res = await note(notification({ type: "DID_RENEW", uuid: "n-5", signedTransactionInfo: await chain.sign(live("2000000000000041", { bundleId: OTHER_BUNDLE })) }));
  assertEquals(res.status, 403, "an envelope for one bundle around a transaction of another");
  res = await post("/appstore", { signedPayload: 5 });
  assertEquals(res.status, 400);
  res = await post("/appstore", "not an object");
  assertEquals(res.status, 400);
  assertEquals(tenants.get(A)!.got.length, 0, "nothing was pushed for any of them");
  // Types that change no subscription, and a purchase that names no account, are answered 200 and ignored.
  res = await note(notification({ type: "TEST", uuid: "n-test" }));
  assertEquals([res.status, (await res.json()).ignored], [200, "TEST"]);
  res = await note(notification({ type: "DID_RENEW", uuid: "n-6", signedTransactionInfo: await chain.sign(live("2000000000000042", { appAccountToken: null })) }));
  assertEquals([res.status, (await res.json()).ignored], [200, "not a pronto subscription"]);
  res = await note(notification({ type: "DID_RENEW", uuid: "n-7", signedTransactionInfo: await chain.sign(live("2000000000000043", { productId: GOLD })) }));
  assertEquals(res.status, 200);
  assertEquals(tenants.get(A)!.got.length, 0);
});

Deno.test("Apple down, or a tenant that will not take it, answers non-2xx and leaves the retry its turn", async () => {
  const { tenants, apple, claim, note, hold } = await setup();
  const tx = live("2000000000000050");
  hold("2000000000000050", 1, tx);
  apple.down = 503;
  let res = await claim(tx);
  assertEquals([res.status, (await res.json()).error], [502, "the App Store is unavailable"]);
  apple.down = 0;
  tenants.get(A)!.refuse = true;
  res = await claim(tx);
  assertEquals(res.status, 502, "a tenant that refuses it");
  tenants.get(A)!.refuse = false;
  assertEquals((await claim(tx)).status, 200, "neither spent the transaction");
  // A notification the same: Apple sends it again, and it lands once the cause has passed.
  const n = notification({ type: "DID_RENEW", uuid: "n-retry", signedTransactionInfo: await chain.sign(tx) });
  apple.down = 500;
  assertEquals((await note(n)).status, 502);
  apple.down = 0;
  assertEquals((await note(n)).status, 200);
  assertEquals(tenants.get(A)!.got.length, 2);
});

Deno.test("what the App Store holds is not lapsed by Stripe's side of the same account", async () => {
  const { tenants, claim, hold, post } = await setup();
  const tx = live("2000000000000060");
  hold("2000000000000060", 1, tx);
  assertEquals((await claim(tx)).status, 200);
  const first = tenants.get(A)!.got[0];
  // The tenant reads it again (resync, with the token it was given): Stripe holds nothing for the account, Apple does.
  const res = await post("/resync", { tenant: A, account: ANA, manage: first.manage, plan: "analysis" });
  assertEquals(res.status, 200);
  // The token's own claims (the tenant checks its signature in production, as every entitlement's is checked above).
  const claims = JSON.parse(atob((await res.json()).token.split(".")[1].replace(/-/g, "+").replace(/_/g, "/")));
  assertEquals([claims.status, claims.through, claims.plan], ["active", first.through, "analysis"]);
  // Both hold, to the later end; one holding, that one; neither, nothing.
  assertEquals(merged({ active: true, through: 10 }, { active: true, through: 20 }), { active: true, through: 20 });
  assertEquals(merged({ active: false, through: 0 }, { active: true, through: 20 }), { active: true, through: 20 });
  assertEquals(merged({ active: true, through: 10 }, { active: false, through: 0 }), { active: true, through: 10 });
  assertEquals(merged({ active: false, through: 0 }, null), { active: false, through: 0 });
});

Deno.test("the App Store is inert until configured: its paths are no endpoints", async () => {
  const { post, tenants } = await setup({ off: true });
  for (const path of ["/appstore", "/appstore/transaction"]) {
    const res = await post(path, { signedPayload: "x", transaction: "x", tenant: A, account: ANA });
    assertEquals([path, res.status], [path, 404]);
  }
  assertEquals(tenants.get(A)!.got.length, 0);
});

Deno.test("signed data: Apple's chain only, valid now, with Apple's extensions on the certificates that sign", async () => {
  const payload = { transactionId: "1", n: 1 };
  // A little ahead: a certificate openssl made starts at the second it was made.
  const now = Date.now() + 10_000;
  assertEquals(await verifySigned(await chain.sign(payload), [chain.rootPem], now), payload);
  const refuses = async (jws: string, roots: string[], at: number, why: string) => {
    try {
      await verifySigned(jws, roots, at);
    } catch (e) {
      assertEquals((e as Error).message, `signed data refused: ${why}`);
      return;
    }
    throw new Error(`${why}: not refused`);
  };
  await refuses(await chain.sign(payload), [rogue.rootPem], now, "not Apple's root");
  await refuses(await chain.sign(payload), [chain.rootPem], now + 60 * DAY, "a certificate is not valid now");
  await refuses(await chain.sign(payload), [chain.rootPem], now - 60 * DAY, "a certificate is not valid now");
  await refuses(await chain.sign(payload, { x5c: ["AAAA"] }), [chain.rootPem], now, "certificate chain");
  await refuses(await chain.sign(payload, { x5c: undefined, alg: "RS256" }), [chain.rootPem], now, "algorithm");
  // A leaf the intermediate issued without Apple's leaf extension (any developer certificate is one) signs nothing.
  const plain = await makeChain({ leafExtension: false });
  await refuses(await plain.sign(payload), [plain.rootPem], now, "not Apple's signing certificates");
  const noIntermediate = await makeChain({ intermediateExtension: false });
  await refuses(await noIntermediate.sign(payload), [noIntermediate.rootPem], now, "not Apple's signing certificates");
  // A signature by another key than the leaf's, under a good chain.
  const other = await rogue.sign(payload);
  const forged = `${(await chain.sign(payload)).split(".").slice(0, 2).join(".")}.${other.split(".")[2]}`;
  await refuses(forged, [chain.rootPem], now, "signature");
});

Deno.test("what an operator sets, and what it must set together", async () => {
  const env = (o: Record<string, string>) => (k: string) => o[k];
  assertEquals(await appstoreConfigFrom(env({})), undefined, "unset: off");
  const apps = JSON.stringify([{ bundleId: BUNDLE, tenant: A, products: { [PREMIUM]: "analysis" } }]);
  const whole = { APPSTORE_APPS: apps, APPSTORE_ROOTS: chain.rootPem, APPSTORE_ISSUER_ID: "i", APPSTORE_KEY_ID: "k", APPSTORE_KEY: key };
  const config = (await appstoreConfigFrom(env(whole)))!;
  assertEquals([config.apps, config.roots.length], [[{ bundleId: BUNDLE, tenant: A, products: { [PREMIUM]: "analysis" }, sandbox: false }], 1]);
  const fails = async (o: Record<string, string>, why: RegExp) => {
    try {
      await appstoreConfigFrom(env(o));
    } catch (e) {
      if (!why.test((e as Error).message)) throw new Error(`wrong failure: ${(e as Error).message}`);
      return;
    }
    throw new Error(`accepted: ${JSON.stringify(Object.keys(o))}`);
  };
  await fails({ APPSTORE_APPS: apps }, /APPSTORE_ROOTS, APPSTORE_ISSUER_ID, APPSTORE_KEY_ID, APPSTORE_KEY must be too/);
  await fails({ ...whole, APPSTORE_APPS: "nope" }, /JSON list/);
  await fails({ ...whole, APPSTORE_APPS: "[]" }, /at least one app/);
  await fails({ ...whole, APPSTORE_APPS: JSON.stringify([{ bundleId: BUNDLE, tenant: "http://a.example", products: { [PREMIUM]: "analysis" } }]) }, /https origin/);
  await fails({ ...whole, APPSTORE_APPS: JSON.stringify([{ bundleId: BUNDLE, tenant: A, products: { [PREMIUM]: "Not A Plan" } }]) }, /not a product id mapped to a plan id/);
  await fails({ ...whole, APPSTORE_APPS: JSON.stringify([{ bundleId: BUNDLE, tenant: A, products: {} }]) }, /products maps/);
  await fails({ ...whole, APPSTORE_APPS: JSON.stringify([{ bundleId: BUNDLE, tenant: A, products: { [PREMIUM]: "a" } }, { bundleId: BUNDLE, tenant: B, products: { [PREMIUM]: "a" } }]) }, /bundle id twice/);
  await fails({ ...whole, APPSTORE_ROOTS: "no certificate here" }, /root certificates/);
  // A key that is no P-256 .p8 stops the broker at start, not at the first purchase (L4).
  await fails({ ...whole, APPSTORE_KEY: "-----BEGIN PRIVATE KEY-----\nAAAA\n-----END PRIVATE KEY-----" }, /APPSTORE_KEY is an App Store Connect \.p8/);
  await fails({ ...whole, APPSTORE_KEY: "p" }, /APPSTORE_KEY is an App Store Connect \.p8/);
});

Deno.test("an account holds a plan only through a transaction of it, bought for the account, in an active subscription", () => {
  const app = { bundleId: BUNDLE, tenant: A, products: { [PREMIUM]: "analysis", [GOLD]: "gold" }, sandbox: false };
  const base = { originalTransactionId: "o", bundleId: BUNDLE, environment: "Production", revocationDate: null };
  const at = Date.now();
  const tx = (over: object) => ({ transactionId: "t", productId: PREMIUM, appAccountToken: ANA, expiresDate: at + DAY, status: 1, ...base, ...over }) as Parameters<typeof heldOf>[0][number];
  assertEquals(heldOf([tx({})], app, ANA, "analysis", at), { active: true, through: Math.floor((at + DAY) / 1000) });
  assertEquals(heldOf([tx({}), tx({ expiresDate: at + 3 * DAY })], app, ANA, "analysis", at).through, Math.floor((at + 3 * DAY) / 1000), "the later end");
  for (const [why, over] of [["expired", { status: 2 }], ["in billing retry", { status: 3 }], ["revoked", { status: 5 }], ["revoked transaction", { revocationDate: at - 1 }],
    ["ended", { expiresDate: at - 1 }], ["no end", { expiresDate: null }], ["another account", { appAccountToken: BEA }], ["another plan", { productId: GOLD }]] as const) {
    assertEquals([why, heldOf([tx(over)], app, ANA, "analysis", at)], [why, { active: false, through: 0 }]);
  }
});

Deno.test("the App Store's paths exist only where it is configured, and read the body a certificate chain needs", async () => {
  for (const path of ["/appstore", "/appstore/transaction"]) {
    assertEquals([endpointRefusal("POST", path, false)?.status, endpointRefusal("POST", path, false, true)?.status, endpointRefusal("GET", path, false, true)?.status], [404, undefined, 405]);
    assertEquals([bodyLimitOf("POST", path), bodyLimitOf("GET", path)], [16384, undefined]);
    // Before a broker is chosen (twoModes): an oversized body is a 413 only where the path exists, else a 404 unread.
    const big = () => new Request(`${ISSUER}${path}`, { method: "POST", body: "x".repeat(16385) });
    assertEquals([(await withCappedBody(big(), false) as Response).status, (await withCappedBody(big(), false, true) as Response).status], [404, 413]);
  }
});

// A certificate's extensions are read by their extnID: the same bytes inside another extension's value (which a requester
// may choose) are no Apple extension. The review's proof of concept (oidsubj.ts), as a chain of the test's own.
Deno.test("Apple's extension is the certificate's own extension, not its bytes found anywhere in it", async () => {
  const payload = { transactionId: "1" };
  const now = Date.now() + 10_000;
  const hidden = await makeChain({ leafOidHidden: true });
  try {
    await verifySigned(await hidden.sign(payload), [hidden.rootPem], now);
    throw new Error("accepted a leaf whose Apple OID bytes sit in another extension's value");
  } catch (e) {
    assertEquals((e as Error).message, "signed data refused: not Apple's signing certificates");
  }
  // The genuine extension still passes.
  assertEquals(await verifySigned(await chain.sign(payload), [chain.rootPem], now), payload);
});

Deno.test("only a CA signs a certificate: a leaf that is a CA, an intermediate that is none, and a path too long are refused", async () => {
  const payload = { transactionId: "1" };
  const now = Date.now() + 10_000;
  const refused = async (c: Chain, why: string) => {
    try {
      await verifySigned(await c.sign(payload), [c.rootPem], now);
    } catch (e) {
      assertEquals((e as Error).message, `signed data refused: ${why}`);
      return;
    }
    throw new Error(`${why}: accepted`);
  };
  await refused(await makeChain({ leafIsCa: true }), "certificate constraints");
  await refused(await makeChain({ intermediateIsCa: false }), "certificate constraints");
  // The root allows no CA below it, but the chain has the intermediate; the intermediate allows none below itself, and the leaf is no CA.
  await refused(await makeChain({ rootPathLen: 0 }), "certificate constraints");
  const tight = await makeChain({ intermediatePathLen: 0, rootPathLen: 1 });
  assertEquals(await verifySigned(await tight.sign(payload), [tight.rootPem], now), payload);
});

Deno.test("a player in Apple's grace period keeps the plan to the grace's end, read from signed renewal info", async () => {
  const { tenants, claim, note, hold, apple } = await setup();
  const got = () => tenants.get(A)!.got;
  const tx = live("2000000000000070", { expiresDate: Date.now() - 1000 });
  const grace = Date.now() + 10 * DAY;
  // A claim for a transaction that has ended is refused as expired, as ever; a notification of the failed renewal is taken, in grace.
  hold("2000000000000070", 4, tx, { renewal: { gracePeriodExpiresDate: grace, environment: "Production" } });
  let res = await note(notification({ type: "DID_FAIL_TO_RENEW", subtype: "GRACE_PERIOD", uuid: "n-grace", signedTransactionInfo: await chain.sign(tx) }));
  assertEquals(res.status, 200, await res.clone().text());
  assertEquals([got().at(-1)!.active, got().at(-1)!.through], [true, Math.floor(grace / 1000)]);
  // Without renewal info (Apple did not say when it ends), or past it, or its renewal info not Apple's: nothing is held.
  hold("2000000000000070", 4, tx);
  await note(notification({ type: "DID_FAIL_TO_RENEW", uuid: "n-g2", signedTransactionInfo: await chain.sign(tx) }));
  assertEquals(got().at(-1)!.active, false, "no end given");
  hold("2000000000000070", 4, tx, { renewal: { gracePeriodExpiresDate: Date.now() - 1000 } });
  await note(notification({ type: "DID_FAIL_TO_RENEW", uuid: "n-g3", signedTransactionInfo: await chain.sign(tx) }));
  assertEquals(got().at(-1)!.active, false, "the grace ended");
  const before = got().length;
  hold("2000000000000070", 4, tx, { renewal: { gracePeriodExpiresDate: grace }, renewalSigner: rogue });
  res = await note(notification({ type: "DID_FAIL_TO_RENEW", uuid: "n-g4", signedTransactionInfo: await chain.sign(tx) }));
  assertEquals([res.status, got().length], [502, before], "unsigned renewal info grants nothing and is no push");
  // Then the grace expires into billing retry (status 3), which holds nothing; a revoked one in grace holds nothing either.
  hold("2000000000000070", 4, tx, { renewal: { gracePeriodExpiresDate: grace } });
  await note(notification({ type: "DID_FAIL_TO_RENEW", uuid: "n-g5", signedTransactionInfo: await chain.sign(tx) }));
  assertEquals(got().at(-1)!.active, true);
  hold("2000000000000070", 3, tx);
  await note(notification({ type: "GRACE_PERIOD_EXPIRED", uuid: "n-g6", signedTransactionInfo: await chain.sign(tx) }));
  assertEquals(got().at(-1)!.active, false);
  hold("2000000000000070", 4, { ...tx, revocationDate: Date.now() - 1000 }, { renewal: { gracePeriodExpiresDate: grace } });
  await note(notification({ type: "REVOKE", uuid: "n-g7", signedTransactionInfo: await chain.sign(tx) }));
  assertEquals(got().at(-1)!.active, false);
  // A claim in the grace is refused as expired (the player's own device sends a current transaction, which a renewal replaces).
  res = await claim(tx);
  assertEquals([res.status, (await res.json()).error], [409, "expired"]);
  assertEquals(apple.calls.length > 0, true);
});

Deno.test("grace is held through the plan's merge and in the read of Apple, and only to its end", () => {
  const app = { bundleId: BUNDLE, tenant: A, products: { [PREMIUM]: "analysis" }, sandbox: false };
  const at = Date.now();
  const tx = (over: object) => ({
    transactionId: "t", originalTransactionId: "o", bundleId: BUNDLE, environment: "Production", productId: PREMIUM, appAccountToken: ANA,
    expiresDate: at - DAY, revocationDate: null, status: 4, graceUntil: at + 2 * DAY, ...over,
  }) as Parameters<typeof heldOf>[0][number];
  assertEquals(heldOf([tx({})], app, ANA, "analysis", at), { active: true, through: Math.floor((at + 2 * DAY) / 1000) });
  for (const [why, over] of [["no grace end", { graceUntil: null }], ["grace ended", { graceUntil: at - 1 }], ["revoked", { revocationDate: at - 2 }], ["billing retry", { status: 3 }]] as const) {
    assertEquals([why, heldOf([tx(over)], app, ANA, "analysis", at)], [why, { active: false, through: 0 }]);
  }
});

Deno.test("a sandbox app is served only by a broker that holds its tenant in the sandbox", () => {
  const app = (sandbox: boolean, tenant = A) => ({ apps: [{ bundleId: BUNDLE, tenant, products: { [PREMIUM]: "analysis" }, sandbox }] });
  checkSandboxApps(app(false), null); // a live app, on any broker
  checkSandboxApps(app(true), /^https:\/\/a\.example$/); // a sandboxed tenant's
  for (const pattern of [null, /^https:\/\/b\.example$/]) {
    try {
      checkSandboxApps(app(true), pattern);
    } catch (e) {
      assertEquals(/sandbox: true, but its tenant https:\/\/a\.example is not one BILLING_SANDBOX_TENANTS holds/.test((e as Error).message), true);
      continue;
    }
    throw new Error(`a sandbox app on a live tenant was accepted (${pattern})`);
  }
});
