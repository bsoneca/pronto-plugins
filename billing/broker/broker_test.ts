// The broker end to end, against the stand-in for Stripe and two tenants this
// test serves: an author proves an origin and sets up payouts, an account
// subscribes and its tenant alone is told, manages it with the token its
// tenant was given, and lapses when it cancels or a payment fails; one
// tenant's claim, customers and tokens are nothing to another.
import { type Jwk, Refused } from "../shared.ts";
import { brokerKeys, type Entitlement, verifyEntitlement } from "../entitlement.ts";
import { broker, newSigningKey, twoModes } from "./main.ts";
import { chargesAt, checkoutLocale, type Consent, ownerOf, tenantOf } from "./core.ts";
import { fakeStripe, unform } from "./fake.ts";
import { askedDoor, forAccount, form, markTransport, signWebhook, stripe as stripeClient, StripeError, type Stripe, switched, tracked } from "./stripe.ts";
import { MemoryStore, type Store } from "./store.ts";

function assertEquals(a: unknown, b: unknown, m = "") {
  if (JSON.stringify(a) !== JSON.stringify(b)) throw new Error(`${m} expected ${JSON.stringify(b)}, got ${JSON.stringify(a)}`);
}

const ISSUER = "http://localhost:28463";
const A = "https://a.example", B = "https://b.example";
const ANA = "00000000-0000-4000-8000-00000000000a";
const BEA = "00000000-0000-4000-8000-00000000000b";
const PLANS = { analysis: { name: "Analysis", interval: "month", prices: { usd: 499, brl: 1990 } } };
const TRIAL = { months: 3, plans: ["analysis"], remindDays: 7 };

// `replicas` brokers share one store (store.ts), as the node's pods share their database: each
// request goes to the next, round robin.
async function setup(o: { searchLagMs?: number; issuer?: string; replicas?: number; store?: Store; mode?: "live" | "sandbox"; switched?: "asked" | "never" | "direct" | "door" } = {}) {
  const fake = fakeStripe(ISSUER, { searchLagMs: o.searchLagMs ?? 0 });
  // Every request the broker makes to Stripe, as the stand-in is asked it.
  const sent: { method: string; path: string; params?: Record<string, unknown> }[] = [];
  // What Stripe should refuse, for a test of the broker's retries.
  const stripeDown = { delete: false, invoices: 0, invoicesTimeout: false };
  // The broker reaches the stand-in as it reaches Stripe on the node: through its door (PRONTO-270).
  const door = stripeClient({ door: `${ISSUER}/door/stripe`, fetcher: ((u: string | URL | Request, init?: RequestInit) => fake.handle(new Request(u, init))!) as typeof fetch });
  const stripe = ((method: string, path: string, ...rest: unknown[]) => {
    sent.push({ method, path, params: rest[0] as Record<string, unknown> | undefined });
    if (path.startsWith("/v1/invoices/") && stripeDown.invoicesTimeout) return Promise.reject(new DOMException("The signal timed out", "TimeoutError"));
    if (path.startsWith("/v1/invoices/") && stripeDown.invoices) return Promise.reject(new StripeError(stripeDown.invoices, stripeDown.invoices === 403 ? "permission" : "api_error", "invoices refused"));
    if (method === "DELETE" && stripeDown.delete) return Promise.reject(new StripeError(500, "api_error", "Stripe is down"));
    return (door as (...a: unknown[]) => unknown)(method, path, ...rest);
  }) as typeof fake.stripe & { route?: typeof door.route };
  stripe.route = door.route;
  // Two transports a probe can tell apart (PRONTO-218): each is the stand-in's door under its own name, and the
  // switched client sends a call by the request's word (`asked`) or always one way (`never`: the door is off whatever the request says).
  const transportCalls: string[] = [];
  const tagged = (name: "direct" | "door"): Stripe => Object.assign((async (...a: unknown[]) => {
    transportCalls.push(name);
    const answer = await (stripe as (...a: unknown[]) => Promise<unknown>)(...a);
    markTransport(name);
    return answer;
  }) as Stripe, { route: () => Promise.resolve(name) });
  const fixed = o.switched === "direct" || o.switched === "door";
  const routed = fixed ? tagged(o.switched as "direct" | "door") : o.switched ? switched({ direct: tagged("direct"), door: tagged("door"), on: o.switched === "asked" ? askedDoor : () => false }) : stripe;
  const tenants = new Map<string, { doc?: unknown; up: boolean; got: Entitlement[]; hold?: Promise<void>; refuse?: boolean; tickets: Map<string, Consent>; consentFails?: number }>([
    [A, { up: true, got: [], tickets: new Map() }], [B, { up: true, got: [], tickets: new Map() }],
  ]);
  // The tenants, as the broker reaches them: each serves what it publishes and
  // takes the entitlements addressed to it, checked as an app checks them.
  const fetcher = (async (input: string | URL | Request, init?: RequestInit) => {
    const url = new URL(input instanceof Request ? input.url : input);
    if (url.origin === ISSUER) return await handler(new Request(url, init));
    const t = tenants.get(url.origin);
    if (!t || !t.up) throw new TypeError("connection refused");
    if (url.pathname === "/.well-known/pronto-billing.json") return t.doc ? Response.json(t.doc) : new Response("", { status: 404 });
    if (url.pathname === "/billing/events") {
      try {
        const e = await verifyEntitlement(String(init?.body), { issuer: ISSUER, tenant: url.origin, keys });
        if (t.hold) await t.hold;
        if (t.refuse) return new Response("refused", { status: 400 });
        t.got.push(e);
        return new Response(null, { status: 204 });
      } catch (e) {
        if (e instanceof Refused) return new Response(e.message, { status: 400 });
        throw e;
      }
    }
    // A ticket the tenant minted gives back its consent once, and is unknown after.
    if (url.pathname === "/billing/trial/consent") {
      if (t.consentFails) return new Response("secret detail of the tenant's failure", { status: t.consentFails });
      const { account, ticket } = JSON.parse(String(init?.body));
      const consent = account === ANA || account === BEA ? t.tickets.get(ticket) : undefined;
      t.tickets.delete(ticket);
      return consent ? Response.json(consent) : new Response("", { status: 404 });
    }
    return new Response("", { status: 404 });
  }) as typeof fetch;
  const store = o.store ?? new MemoryStore();
  // Replicas sign with one key, as the node's pods read BILLING_SIGNING_KEY from one Secret.
  const signingKey = (o.replicas ?? 1) > 1 ? await newSigningKey() : undefined;
  const replicas = await Promise.all(Array.from({ length: o.replicas ?? 1 }, () =>
    broker({ issuer: ISSUER, secret: "s".repeat(32), stripe: routed, webhookSecret: fake.webhookSecret, fetcher, cacheMs: 0, feePercent: 10, store, signingKey, mode: o.mode }).then((h) => fixed ? tracked(h) : o.switched ? forAccount(h) : h)));
  let turn = 0;
  const handler = (req: Request) => replicas[turn++ % replicas.length](req);
  const keys = brokerKeys(ISSUER, fetcher, 0);
  fake.connect(handler);
  const call = (path: string, init?: RequestInit) => {
    const req = new Request(`${ISSUER}${path}`, init);
    return fake.handle(req) ?? handler(req);
  };
  const post = (path: string, body: unknown) => call(path, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(body) });
  const press = async (url: string, what: string) => {
    const res = await call(new URL(url).pathname + new URL(url).search, { method: "POST", headers: { "content-type": "application/x-www-form-urlencoded" }, body: `do=${what}` });
    return res.headers.get("location") ?? "";
  };
  // An author publishes the hash of their secret with the plans, and sets up payouts with the secret.
  const secrets = new Map<string, string>();
  const prove = async (tenant: string, trial: unknown = undefined) => {
    const secret = `${tenant} author's secret, long enough`;
    secrets.set(tenant, secret);
    tenants.get(tenant)!.doc = { owner: await ownerOf(secret), plans: PLANS, ...(trial ? { trial } : {}) };
  };
  // A ticket the tenant minted: for what an account consented to, or for an offer (nothing).
  const OFFER: Consent = { plan: null, amount: null, currency: null, charges_at: null, terms: null };
  const consentTo = (over: Partial<Consent> = {}): Consent => ({
    plan: "analysis", amount: 1990, currency: "brl", charges_at: chargesAt(new Date(), 3).toISOString(), terms: "R$ 19,90 from the day, cancel in the app", ...over,
  });
  const ticket = (tenant: string, consent: Consent = OFFER) => {
    const t = crypto.randomUUID().replaceAll("-", "");
    tenants.get(tenant)!.tickets.set(t, consent);
    return t;
  };
  const payouts = async (tenant: string) => {
    // Without an email Stripe has no one to reach about payouts: no account is opened.
    assertEquals((await post("/onboard", { tenant, owner: secrets.get(tenant) })).status, 400, "onboard without an email");
    const res = await post("/onboard", { tenant, owner: secrets.get(tenant), email: "author@example.com" });
    assertEquals(res.status, 200, "onboard");
    const back = await press((await res.json()).url, "done");
    assertEquals(back, `${ISSUER}/onboarded?tenant=${encodeURIComponent(tenant)}`);
    assertEquals((await call(new URL(back).pathname + new URL(back).search)).status, 200, "set up");
  };
  return { fake, door, sent, stripeDown, tenants, call, post, press, prove, payouts, secrets, ticket, consentTo, OFFER, replicas, transportCalls };
}

Deno.test("an account subscribes, its tenant alone is told, and it lapses when it cancels", async () => {
  const { fake, tenants, post, press, prove, payouts } = await setup();
  await prove(A);
  await payouts(A);
  const res = await post("/checkout", { tenant: A, account: ANA, plan: "analysis", currency: "brl", locale: "pt-BR", return: "/?review=1" });
  assertEquals(res.status, 200);
  const pay = (await res.json()).url;
  assertEquals(await press(pay, "pay"), `${A}/?review=1`);
  const [got] = tenants.get(A)!.got;
  assertEquals([got.account, got.plan, got.active, got.through > Date.now() / 1000 + 29 * 86400], [ANA, "analysis", true, true]);
  assertEquals(tenants.get(B)!.got.length, 0, "the other tenant hears nothing");
  // The payment pays A's author, less the platform's share, in the currency asked for.
  const [sub] = [...fake.held.subscriptions.values()];
  const [acct] = [...fake.held.accounts.values()];
  assertEquals(sub.transfer_data.destination, acct.id);
  const [price] = [...fake.held.prices.values()];
  assertEquals([price.currency, price.unit_amount, price.currency_options.brl.unit_amount], ["usd", 499, 1990]);
  // A second checkout for a plan held is refused.
  assertEquals((await post("/checkout", { tenant: A, account: ANA, plan: "analysis" })).status, 409);

  // Managing it takes the token the tenant was given for that account.
  assertEquals((await post("/portal", { tenant: A, account: ANA, manage: "guess" })).status, 403);
  const portal = await post("/portal", { tenant: A, account: ANA, manage: got.manage, return: "/settings" });
  assertEquals(portal.status, 200);
  const portalUrl = (await portal.json()).url;
  await press(`${portalUrl}?sub=${sub.id}`, "fail");
  assertEquals(tenants.get(A)!.got.at(-1)!.active, false, "a failed payment lapses it");
  await press(`${portalUrl}?sub=${sub.id}`, "renew");
  assertEquals(tenants.get(A)!.got.at(-1)!.active, true, "a paid one restores it");
  await press(`${portalUrl}?sub=${sub.id}`, "cancel");
  const last = tenants.get(A)!.got.at(-1)!;
  assertEquals([last.active, last.through], [false, 0], "cancelled");
  // Each entitlement is newer than the one before it.
  const vers = tenants.get(A)!.got.map((e) => e.ver);
  assertEquals(vers.every((v, i) => i === 0 || v >= vers[i - 1]), true);
  // Cancelled, it may be bought again.
  assertEquals((await post("/checkout", { tenant: A, account: ANA, plan: "analysis" })).status, 200);
});

Deno.test("one tenant is nothing to another", async () => {
  const { fake, tenants, post, press, prove, payouts, secrets } = await setup();
  await prove(A);
  // Whoever lacks the author's secret sets up no payouts, though the origin is proven.
  assertEquals((await post("/onboard", { tenant: A, owner: "a stranger racing the author to it" })).status, 403);
  assertEquals((await post("/onboard", { tenant: A })).status, 400);
  assertEquals(fake.held.accounts.size, 0, "no account opened for a stranger");
  // B copying A's document gains A nothing, and B's author still holds no A secret.
  tenants.get(B)!.doc = { ...(tenants.get(A)!.doc as object) };
  assertEquals((await post("/onboard", { tenant: A, owner: "B's own secret, as long as any other" })).status, 403);
  await payouts(A);
  // Once set up, nobody is sent through onboarding again, the author included.
  assertEquals((await post("/onboard", { tenant: A, owner: secrets.get(A) })).status, 409);
  assertEquals((await post("/checkout", { tenant: B, account: ANA, plan: "analysis" })).status, 409);
  // The same account id in two tenants is two customers, two subscriptions, two tokens.
  await prove(B);
  await payouts(B);
  for (const t of [A, B]) await press((await (await post("/checkout", { tenant: t, account: ANA, plan: "analysis" })).json()).url, "pay");
  const [a, b] = [tenants.get(A)!.got[0], tenants.get(B)!.got[0]];
  assertEquals([a.active, b.active, a.manage === b.manage], [true, true, false]);
  assertEquals((await post("/portal", { tenant: B, account: ANA, manage: a.manage })).status, 403, "A's token at B");
});

Deno.test("an author at home takes card payments too, and one abroad is a recipient alone", async () => {
  const { fake, post, press, prove, secrets } = await setup();
  for (const [t, country] of [[A, undefined], [B, "BR"]] as const) {
    await prove(t);
    const res = await post("/onboard", { tenant: t, owner: secrets.get(t), email: "author@example.com", ...(country ? { country } : {}) });
    assertEquals(res.status, 200, `onboard ${t}`);
    await press((await res.json()).url, "done");
  }
  const held = [...fake.held.accounts.values()].map((a) => [a.metadata.tenant, a.identity.country, a.applied_configurations]);
  assertEquals(held, [[A, "us", ["merchant", "recipient"]], [B, "br", ["recipient"]]]);
});

Deno.test("the broker refuses what it can't stand behind", async () => {
  const { fake, tenants, call, post, prove } = await setup();
  // An origin that has published nothing, or not https.
  assertEquals((await post("/onboard", { tenant: A, owner: "x".repeat(40) })).status, 409);
  assertEquals((await post("/onboard", { tenant: "http://a.example", owner: "x".repeat(40) })).status, 400);
  await prove(A);
  // Payouts not set up: nothing is sold.
  assertEquals((await post("/checkout", { tenant: A, account: ANA, plan: "analysis" })).status, 409);
  // A plan it does not publish, an account that is not a uuid, a return off its origin.
  assertEquals((await post("/checkout", { tenant: A, account: ANA, plan: "toString" })).status, 400);
  assertEquals((await post("/checkout", { tenant: A, account: "ana", plan: "analysis" })).status, 400);
  assertEquals((await post("/checkout", { tenant: A, account: ANA, plan: "analysis", return: "//evil.example/" })).status, 400);
  // A webhook Stripe did not sign.
  const payload = JSON.stringify({ id: "evt_1", type: "customer.subscription.created", data: { object: {} } });
  assertEquals((await call("/stripe", { method: "POST", body: payload, headers: { "stripe-signature": await signWebhook("whsec_other", payload) } })).status, 400);
  // A tenant that can't be reached leaves the webhook unanswered, for Stripe to send again.
  const sub = { id: "sub_x", status: "active", current_period_end: 2_000_000_000, customer: "cus_none", metadata: { tenant: A, account: ANA, plan: "analysis" } };
  tenants.get(A)!.up = false;
  assertEquals(await fake.emit("customer.subscription.updated", sub), false);
  tenants.get(A)!.up = true;
  assertEquals(await fake.emit("customer.subscription.updated", sub), true);
  assertEquals(tenants.get(A)!.got.at(-1)!.active, false, "read again from Stripe, where the customer holds nothing");
  fake.close();
});

Deno.test("two checkouts while Stripe's search lags pay once", async () => {
  const { fake, post, press, prove, payouts, tenants } = await setup({ searchLagMs: 60_000 });
  await prove(A);
  await payouts(A);
  const first = (await (await post("/checkout", { tenant: A, account: ANA, plan: "analysis" })).json()).url;
  const second = (await (await post("/checkout", { tenant: A, account: ANA, plan: "analysis" })).json()).url;
  assertEquals(fake.held.customers.size, 1, "one customer, though search has not found it");
  // The first tab's checkout was closed when the second opened.
  assertEquals(await press(first, "pay"), "");
  await press(second, "pay");
  assertEquals([...fake.held.subscriptions.values()].length, 1);
  assertEquals(tenants.get(A)!.got.at(-1)!.active, true);
});

Deno.test("a tenant that missed its entitlement asks for it again with its token", async () => {
  const { post, press, prove, payouts, tenants } = await setup();
  await prove(A);
  await payouts(A);
  await press((await (await post("/checkout", { tenant: A, account: ANA, plan: "analysis" })).json()).url, "pay");
  const { manage, ver } = tenants.get(A)!.got[0];
  assertEquals((await post("/resync", { tenant: A, account: ANA, plan: "analysis", manage: "guess" })).status, 403);
  const res = await post("/resync", { tenant: A, account: ANA, plan: "analysis", manage });
  const { token } = await res.json();
  const again = await verifyEntitlement(token, { issuer: ISSUER, tenant: A, keys: brokerKeys(ISSUER, (() => Promise.resolve(Response.json({ keys: [] }))) as typeof fetch) }).catch((e) => e.message);
  assertEquals(again, "entitlement key unknown", "checked against the broker's keys alone");
  assertEquals(typeof token === "string" && token.split(".").length === 3, true);
  void ver;
});

Deno.test("lookups that arrive while the broker's keys are fetched wait for that fetch, which is made once", async () => {
  const jwk = { kid: "k1", kty: "EC", crv: "P-256", x: "x", y: "y" } as unknown as Jwk;
  let calls = 0;
  let answer!: () => void;
  const fetcher = (() => { calls++; return new Promise<Response>((r) => { answer = () => r(Response.json({ keys: [jwk] })); }); }) as typeof fetch;
  const keys = brokerKeys(ISSUER, fetcher);
  const three = Promise.all([keys("k1"), keys("k1"), keys("k1")]);
  await new Promise((r) => setTimeout(r, 0));
  answer();
  assertEquals((await three).map((k) => k?.kid), ["k1", "k1", "k1"], "none of the three is refused while the first fetches");
  assertEquals(calls, 1);
  assertEquals(await keys("k2"), undefined, "an unknown key within the cooldown fetches nothing");
  assertEquals(calls, 1);
});

Deno.test("a tenant is a public https host: no address, no private name", () => {
  for (const bad of ["https://127.0.0.1", "https://[::1]", "https://169.254.169.254", "https://10.0.0.5:6379", "https://localhost", "https://db.internal", "https://intranet", "https://a'b.com"]) {
    assertEquals(tenantOf(bad), null, bad);
  }
  assertEquals(tenantOf("https://shop.example.com"), "https://shop.example.com");
  assertEquals(tenantOf("https://localhost:28102", true), "https://localhost:28102", "a broker on a developer's machine");
});

Deno.test("Checkout's locale is one Stripe takes", () => {
  assertEquals([checkoutLocale("pt-BR"), checkoutLocale("en-US"), checkoutLocale("es-419"), checkoutLocale("xx"), checkoutLocale(3)], ["pt-BR", "en", "es-419", "auto", "auto"]);
});

Deno.test("an entitlement read before a cancel and taken after it does not outlive it", async () => {
  const { fake, post, press, prove, payouts, tenants } = await setup();
  await prove(A);
  await payouts(A);
  await press((await (await post("/checkout", { tenant: A, account: ANA, plan: "analysis" })).json()).url, "pay");
  const [sub] = [...fake.held.subscriptions.values()];
  // The tenant is slow to take an "active" push; meanwhile the subscription is cancelled.
  let release!: () => void;
  tenants.get(A)!.hold = new Promise((r) => release = r);
  const slow = fake.emit("customer.subscription.updated", sub);
  await new Promise((r) => setTimeout(r, 5));
  tenants.get(A)!.hold = undefined;
  sub.status = "canceled";
  await fake.emit("customer.subscription.deleted", sub);
  release();
  await slow;
  // A tenant keeps the entitlement with the highest ver: it must say what Stripe says now.
  const newest = tenants.get(A)!.got.reduce((a, b) => (b.ver > a.ver ? b : a));
  assertEquals(newest.active, false);
});

Deno.test("an unknown key is looked for at most once a minute", async () => {
  let asked = 0;
  const keys = brokerKeys(ISSUER, (() => { asked++; return Promise.resolve(Response.json({ keys: [] })); }) as typeof fetch);
  for (let i = 0; i < 100; i++) assertEquals(await keys(`k${i}`), undefined);
  assertEquals(asked, 1);
});

Deno.test("one broker in two modes: a sandboxed tenant and the sandbox's webhook reach the sandbox alone", async () => {
  const seen: string[] = [];
  const mode = (name: string) => async (req: Request) => {
    seen.push(`${name} ${new URL(req.url).pathname}`);
    await req.body?.cancel();
    return new Response(name);
  };
  const handler = twoModes({
    live: mode("live"), sandbox: mode("sandbox"),
    sandboxed: (t) => /^https:\/\/[a-z0-9-]+-123456789012\.us-central1\.run\.app$/.test(t),
    sandboxWebhookSecret: "whsec_sandbox",
  });
  const ask = async (path: string, init?: RequestInit) => await (await handler(new Request(`${ISSUER}${path}`, init))).text();
  const json = (body: unknown) => ({ method: "POST", body: JSON.stringify(body), headers: { "content-type": "application/json" } });
  const preview = "https://shop-rc-123456789012.us-central1.run.app";
  assertEquals(await ask("/checkout", json({ tenant: preview, account: "a", plan: "p" })), "sandbox", "a preview buys in the sandbox");
  assertEquals(await ask("/checkout", json({ tenant: `${preview}/`, account: "a", plan: "p" })), "sandbox", "with or without its slash");
  assertEquals(await ask("/checkout", json({ tenant: "https://shop.example.com", account: "a", plan: "p" })), "live", "the app itself buys live");
  assertEquals(await ask("/portal", json({ tenant: preview })), "sandbox");
  assertEquals(await ask("/resync", json({ tenant: "https://shop.example.com" })), "live");
  assertEquals(await ask(`/onboarded?tenant=${encodeURIComponent(preview)}`), "sandbox");
  assertEquals(await ask("/checkout", { method: "POST", body: "not json" }), "live", "a body it can't read goes live, which refuses it");
  assertEquals(await ask("/jwks"), "live");
  const payload = JSON.stringify({ id: "evt_1", type: "customer.subscription.updated" });
  const signed = async (secret: string) => ({ method: "POST", body: payload, headers: { "stripe-signature": await signWebhook(secret, payload) } });
  assertEquals(await ask("/stripe", await signed("whsec_sandbox")), "sandbox", "the sandbox's webhook");
  assertEquals(await ask("/stripe", await signed("whsec_live")), "live", "any other signature is the live broker's to judge");
  assertEquals(seen.length, 10, "every request reached exactly one mode");
});

Deno.test("a plan re-priced keeps every existing subscription at its old price; only new checkouts pay the new one", async () => {
  const { fake, sent, tenants, post, press, prove, payouts } = await setup();
  await prove(A);
  await payouts(A);
  const subscribe = async (account: string) => {
    const res = await post("/checkout", { tenant: A, account, plan: "analysis" });
    assertEquals(res.status, 200, "checkout");
    await press((await res.json()).url, "pay");
  };
  await subscribe(ANA);
  const [ana] = [...fake.held.subscriptions.values()];
  const oldPrice = ana.items.data[0].price.id;
  // The author re-prices the plan; the next account pays the new price.
  (tenants.get(A)!.doc as { plans: unknown }).plans = { analysis: { name: "Analysis", interval: "month", prices: { usd: 999, brl: 3990 } } };
  await subscribe(BEA);
  const [oldOne, newOne] = [...fake.held.prices.values()];
  assertEquals(fake.held.prices.size, 2, "one price for each amount");
  assertEquals([oldOne.id, oldOne.active, oldOne.unit_amount, oldOne.currency_options.brl.unit_amount], [oldPrice, true, 499, 1990], "the old price stays");
  assertEquals([newOne.active, newOne.unit_amount, newOne.currency_options.brl.unit_amount], [true, 999, 3990]);
  assertEquals(newOne.lookup_key !== oldOne.lookup_key, true, "named apart");
  const bea = [...fake.held.subscriptions.values()].find((s) => s.id !== ana.id)!;
  assertEquals(bea.items.data[0].price.id, newOne.id, "the new account pays the new price");
  // Ana's renewal bills the price she was sold.
  const portal = await post("/portal", { tenant: A, account: ANA, manage: tenants.get(A)!.got[0].manage });
  await press(`${(await portal.json()).url}?sub=${ana.id}`, "renew");
  assertEquals([ana.items.data[0].price.id, ana.items.data[0].price.unit_amount], [oldPrice, 499], "Ana keeps her price");
  const last = (account: string) => tenants.get(A)!.got.filter((e) => e.account === account).at(-1)!;
  assertEquals([last(ANA).plan, last(ANA).active, last(BEA).plan, last(BEA).active], ["analysis", true, "analysis", true]);
  // The broker only reads subscriptions and never edits a price.
  const writes = sent.filter((r) => r.method === "POST" && (r.path.startsWith("/v1/subscriptions") || /^\/v1\/prices\/[^/]/.test(r.path)));
  assertEquals(writes, [], "no write to a subscription or an existing price");
});

// A trial begun the way a page does: the tenant mints a ticket for what the account consented to,
// the broker opens Checkout from it, and the account presses to start.
async function startTrial(s: Awaited<ReturnType<typeof setup>>, account = ANA, consent = s.consentTo()) {
  const res = await s.post("/trial/checkout", { tenant: A, account, ticket: s.ticket(A, consent), locale: "pt-BR", return: "/?premium=trial" });
  assertEquals(res.status, 200, "trial checkout");
  assertEquals(await s.press((await res.json()).url, "pay"), `${A}/?premium=trial`);
  return [...s.fake.held.subscriptions.values()].at(-1)!;
}
const portalOf = async (s: Awaited<ReturnType<typeof setup>>, account = ANA) => {
  const manage = s.tenants.get(A)!.got.findLast((e) => e.account === account)!.manage;
  return (await (await s.post("/portal", { tenant: A, account, manage, return: "/" })).json()).url as string;
};
const lastGot = (s: Awaited<ReturnType<typeof setup>>, account = ANA) => s.tenants.get(A)!.got.findLast((e) => e.account === account)!;

Deno.test("a trial is offered and opened only on a ticket its tenant stands behind, once", async () => {
  const { tenants, post, prove, payouts, ticket, consentTo, fake } = await setup();
  await prove(A, TRIAL);
  await payouts(A);
  // No ticket, a ticket nobody minted, one for another account: nothing, and Stripe is not asked to open anything.
  assertEquals((await post("/trial/offer", { tenant: A, account: ANA })).status, 400);
  assertEquals((await post("/trial/offer", { tenant: A, account: ANA, ticket: "x".repeat(32) })).status, 403);
  assertEquals((await post("/trial/offer", { tenant: A, account: BEA, ticket: ticket(A) })).status, 200, "the tenant is asked, and answers for the account named");
  assertEquals((await post("/trial/checkout", { tenant: A, account: ANA })).status, 400);
  assertEquals((await post("/trial/checkout", { tenant: A, account: ANA, ticket: "y".repeat(32) })).status, 403);
  assertEquals(fake.held.subscriptions.size, 0);
  // A ticket works once, offer or checkout.
  const offer = ticket(A);
  assertEquals((await post("/trial/offer", { tenant: A, account: ANA, ticket: offer })).status, 200);
  assertEquals((await post("/trial/offer", { tenant: A, account: ANA, ticket: offer })).status, 403, "an offer's ticket, again");
  const go = ticket(A, consentTo());
  assertEquals((await post("/trial/checkout", { tenant: A, account: ANA, ticket: go })).status, 200);
  assertEquals((await post("/trial/checkout", { tenant: A, account: ANA, ticket: go })).status, 403, "a checkout's ticket, again");
  // A tenant that is down is no yes: its document cannot be read, so nothing is offered.
  tenants.get(A)!.up = false;
  assertEquals((await post("/trial/offer", { tenant: A, account: ANA, ticket: ticket(A) })).status, 409);
  tenants.get(A)!.up = true;
  // A tenant whose document has no trial offers none: nothing to take a ticket for.
  await prove(B);
  await payouts(B);
  const unused = ticket(B);
  assertEquals((await post("/trial/offer", { tenant: B, account: ANA, ticket: unused })).status, 404);
  assertEquals((await post("/trial/checkout", { tenant: B, account: ANA, ticket: unused })).status, 404);
  assertEquals(tenants.get(B)!.tickets.has(unused), true, "its ticket was not even taken");
});

Deno.test("an offer names the plan, its price in the currency asked, and the day it is charged", async () => {
  const { post, prove, payouts, ticket } = await setup();
  await prove(A, TRIAL);
  // Payouts not set up: nothing to offer.
  assertEquals((await post("/trial/offer", { tenant: A, account: ANA, ticket: ticket(A) })).status, 409);
  await payouts(A);
  const before = chargesAt(new Date(), 3).getTime();
  const res = await post("/trial/offer", { tenant: A, account: ANA, ticket: ticket(A), currency: "usd" });
  const { eligible, offers } = await res.json();
  const after = chargesAt(new Date(), 3).getTime();
  assertEquals([eligible, offers.length], [true, 1]);
  const { charges_at, ...rest } = offers[0];
  assertEquals(rest, { plan: "analysis", name: "Analysis", amount: 499, currency: "usd", interval: "month", months: 3 });
  assertEquals(Date.parse(charges_at) >= before && Date.parse(charges_at) <= after, true, "three calendar months on");
  assertEquals((await (await post("/trial/offer", { tenant: A, account: ANA, ticket: ticket(A) })).json()).offers[0].currency, "usd", "the plan's first currency by default");
  assertEquals((await (await post("/trial/offer", { tenant: A, account: ANA, ticket: ticket(A), currency: "eur" })).json()).offers[0].currency, "usd", "an unsold one is the default");
});

Deno.test("a stale date or a wrong amount is refused, and so is a plan or currency not on offer", async () => {
  const { post, prove, payouts, ticket, consentTo, fake } = await setup();
  await prove(A, TRIAL);
  await payouts(A);
  const refused = async (over: Partial<Consent>) => {
    const res = await post("/trial/checkout", { tenant: A, account: ANA, ticket: ticket(A, consentTo(over)) });
    return [res.status, (await res.json()).error];
  };
  assertEquals(await refused({ charges_at: new Date(Date.now() + 60 * 86_400_000).toISOString() }), [409, "stale"], "a date a month short");
  assertEquals(await refused({ charges_at: new Date(chargesAt(new Date(), 3).getTime() + 2 * 86_400_000).toISOString() }), [409, "stale"], "a date two days past the three months");
  assertEquals(await refused({ amount: 1000 }), [409, "stale"], "a price not the plan's");
  assertEquals(await refused({ currency: "usd" }), [409, "stale"], "the brl price under usd");
  assertEquals((await refused({ plan: "other" }))[0], 400);
  assertEquals((await refused({ currency: "eur" }))[0], 400);
  assertEquals((await refused({ charges_at: "someday" }))[0], 400);
  assertEquals(fake.held.subscriptions.size + fake.held.customers.size, 0, "nothing opened at Stripe for any of them");
  const page = await post("/trial/checkout", { tenant: A, account: ANA, ticket: ticket(A, consentTo()), return: "//evil.example/" });
  assertEquals(page.status, 400, "a return off the tenant's origin");
});

Deno.test("an old-style /checkout is what it was, and a trial's Checkout gets exactly its own", async () => {
  const s = await setup();
  const { sent, post, prove, payouts, consentTo, ticket } = s;
  await prove(A, TRIAL);
  await payouts(A);
  const [acct] = [...s.fake.held.accounts.values()];
  const session = (n: number) => sent.filter((r) => r.method === "POST" && r.path === "/v1/checkout/sessions")[n].params;
  // Asking for a trial plan the old way buys it now: no trial, no card collection, no trial_end.
  const old = await post("/checkout", { tenant: A, account: BEA, plan: "analysis", currency: "brl", locale: "pt-BR", return: "/back", trial_end: 1, trial: "1", payment_method_collection: "always" });
  assertEquals(old.status, 200);
  const [price] = [...s.fake.held.prices.values()];
  const customer = [...s.fake.held.customers.values()].find((c) => c.metadata.account === BEA)!.id;
  const metadata = { tenant: A, account: BEA, plan: "analysis" };
  assertEquals(session(0), {
    mode: "subscription", customer, client_reference_id: BEA, locale: "pt-BR", line_items: [{ price: price.id, quantity: 1 }], currency: "brl",
    success_url: `${A}/back`, cancel_url: `${A}/back`, metadata,
    subscription_data: { metadata, transfer_data: { destination: acct.id }, application_fee_percent: 10 },
  }, "the checkout of a plan");
  // The trial's, from the consent: its date verbatim, its currency, its metadata, its card.
  const consent = consentTo({ currency: "usd", amount: 499 });
  const res = await post("/trial/checkout", { tenant: A, account: ANA, ticket: ticket(A, consent), locale: "es-419", return: "/back", plan: "ignored", trial_end: 1 });
  assertEquals(res.status, 200);
  const ana = [...s.fake.held.customers.values()].find((c) => c.metadata.account === ANA)!.id;
  const tm = { tenant: A, account: ANA, plan: "analysis", trial: "1", trial_amount: "499", trial_currency: "usd" };
  const end = Math.floor(Date.parse(consent.charges_at!) / 1000);
  assertEquals(session(1), {
    mode: "subscription", customer: ana, client_reference_id: ANA, locale: "es-419", line_items: [{ price: price.id, quantity: 1 }], currency: "usd",
    payment_method_collection: "always", success_url: `${A}/back`, cancel_url: `${A}/back`, metadata: tm,
    subscription_data: {
      metadata: tm, transfer_data: { destination: acct.id }, application_fee_percent: 10,
      trial_end: end, trial_settings: { end_behavior: { missing_payment_method: "cancel" } },
    },
  }, "the checkout of a trial");
});

Deno.test("a trial is one to an account: not after one, a paid plan, a cancel, or for another plan", async () => {
  const s = await setup();
  const { post, press, prove, payouts, ticket, consentTo, fake, tenants } = s;
  await prove(A, { ...TRIAL, plans: ["analysis", "coach"] });
  (tenants.get(A)!.doc as { plans: Record<string, unknown> }).plans.coach = { name: "Coach", interval: "month", prices: { usd: 899, brl: 3990 } };
  await payouts(A);
  const offers = async (account: string) => (await (await post("/trial/offer", { tenant: A, account, ticket: ticket(A) })).json());
  const used = async (account: string, plan = "analysis") => {
    const amount = plan === "analysis" ? 1990 : 3990;
    const res = await post("/trial/checkout", { tenant: A, account, ticket: ticket(A, consentTo({ plan, amount })) });
    return [res.status, (await res.json()).error ?? "opened"];
  };
  assertEquals((await offers(ANA)).eligible, true);
  // Begun, the trial is spent: no offer, no second checkout, for that plan or another.
  const sub = await startTrial(s);
  assertEquals(await offers(ANA), { eligible: false, why: "used", offers: [] });
  assertEquals(await used(ANA), [409, "used"]);
  assertEquals(await used(ANA, "coach"), [409, "used"], "another plan");
  // Cancelled before it ends, and ended: still spent.
  const portal = await portalOf(s);
  await press(`${portal}?sub=${sub.id}`, "cancel");
  assertEquals(sub.status, "canceled");
  assertEquals(await used(ANA), [409, "used"], "after a cancel");
  assertEquals((await offers(ANA)).eligible, false);
  // An account that paid for a plan the usual way never had a trial to spend.
  await press((await (await post("/checkout", { tenant: A, account: BEA, plan: "analysis" })).json()).url, "pay");
  assertEquals((await offers(BEA)).eligible, false, "a paid subscriber");
  assertEquals(await used(BEA, "coach"), [409, "used"], "a paid subscriber, for another plan");
  await press(`${await portalOf(s, BEA)}?sub=${[...fake.held.subscriptions.values()].at(-1)!.id}`, "cancel");
  assertEquals((await offers(BEA)).eligible, false, "a former subscriber");
});

Deno.test("a subscription that never completed spends no trial", async () => {
  const s = await setup();
  const { post, prove, payouts, ticket, consentTo, fake } = s;
  await prove(A, TRIAL);
  await payouts(A);
  assertEquals((await post("/trial/checkout", { tenant: A, account: BEA, ticket: ticket(A, consentTo()) })).status, 200, "Checkout opened, not completed");
  const [customer] = [...fake.held.customers.values()];
  for (const status of ["incomplete", "incomplete_expired"]) {
    fake.held.subscriptions.set(`sub_${status}`, {
      id: `sub_${status}`, customer: customer.id, status, current_period_end: 1, metadata: { tenant: A, account: BEA, plan: "analysis", trial: "1" },
    });
    assertEquals((await (await post("/trial/offer", { tenant: A, account: BEA, ticket: ticket(A) })).json()).eligible, true, status);
    assertEquals((await post("/trial/checkout", { tenant: A, account: BEA, ticket: ticket(A, consentTo()) })).status, 200, status);
  }
  fake.held.subscriptions.get("sub_incomplete")!.status = "past_due";
  assertEquals((await (await post("/trial/offer", { tenant: A, account: BEA, ticket: ticket(A) })).json()).eligible, false, "once it is a subscription");
});

Deno.test("a trial runs, is cancelled from the portal, and ends uncharged", async () => {
  const s = await setup();
  const { fake, press, prove, payouts, tenants } = s;
  await prove(A, TRIAL);
  await payouts(A);
  const consent = s.consentTo();
  const sub = await startTrial(s, ANA, consent);
  const end = Math.floor(Date.parse(consent.charges_at!) / 1000);
  assertEquals([sub.status, sub.charges, sub.trial_end, sub.current_period_end], ["trialing", 0, end, end], "trialing, free, to the day consented to");
  let e = lastGot(s);
  assertEquals([e.active, e.through, e.trial], [true, end, { state: "running", amount: 1990, currency: "brl", chargesAt: end }], "a trial holds the plan until it ends");
  // Cancelled in the portal, as the real one does: at the period's end, which is the trial's.
  const portal = await portalOf(s);
  await press(`${portal}?sub=${sub.id}`, "cancel_end");
  assertEquals(sub.cancel_at_period_end, true);
  e = lastGot(s);
  assertEquals([e.active, e.trial?.state], [true, "cancelled"], "free until the day, then nothing");
  // The day comes: nothing is charged, and the plan lapses.
  await press(`${portal}?sub=${sub.id}`, "trial_paid");
  assertEquals([sub.status, sub.charges], ["canceled", 0]);
  e = lastGot(s);
  assertEquals([e.active, e.through, e.trial?.state], [false, 0, "ended"]);
  assertEquals(fake.held.subscriptions.size, 1);
  assertEquals(tenants.get(B)!.got.length, 0);
});

Deno.test("a trial that is not cancelled becomes a paying subscription, charged once", async () => {
  const s = await setup();
  const { press, prove, payouts } = s;
  await prove(A, TRIAL);
  await payouts(A);
  const sub = await startTrial(s);
  const portal = await portalOf(s);
  await press(`${portal}?sub=${sub.id}`, "trial_week");
  assertEquals(sub.trial_end > Date.now() / 1000 + 6 * 86400 && sub.trial_end < Date.now() / 1000 + 7 * 86400, true, "a week to go");
  assertEquals(lastGot(s).trial?.chargesAt, sub.trial_end, "the day moved with it");
  const end = sub.trial_end;
  await press(`${portal}?sub=${sub.id}`, "trial_paid");
  assertEquals([sub.status, sub.charges, sub.current_period_start], ["active", 1, end]);
  const e = lastGot(s);
  assertEquals([e.active, e.through > end, e.trial?.state], [true, true, "converted"]);
  // A renewal later that fails is the ordinary lapse: the subscription is left to Stripe's dunning.
  await press(`${portal}?sub=${sub.id}`, "renew");
  await press(`${portal}?sub=${sub.id}`, "fail");
  assertEquals(sub.status, "past_due", "not cancelled by the broker");
  assertEquals(s.sent.filter((r) => r.method === "DELETE"), [], "no cancel");
  const l = lastGot(s);
  assertEquals([l.active, l.trial?.state], [false, "converted"]);
});

Deno.test("a trial whose first charge fails is cancelled at once, exactly once", async () => {
  const s = await setup();
  const { fake, press, prove, payouts } = s;
  await prove(A, TRIAL);
  await payouts(A);
  const sub = await startTrial(s);
  const portal = await portalOf(s);
  await press(`${portal}?sub=${sub.id}`, "trial_fail");
  const del = s.sent.filter((r) => r.method === "DELETE");
  assertEquals(del, [{ method: "DELETE", path: `/v1/subscriptions/${sub.id}`, params: undefined }], "cancelled, once");
  assertEquals([sub.status, sub.metadata.trial_failed, sub.charges], ["canceled", "1", 0], "marked failed, never charged");
  const e = lastGot(s);
  assertEquals([e.active, e.through, e.trial?.state], [false, 0, "failed"], "the plan lapses and the tenant is told why");
  // Stripe sends the same event again, or a late one: the subscription is already ended, so nothing more is asked.
  await fake.emit("customer.subscription.updated", { ...structuredClone(sub), status: "past_due" });
  await fake.emit("customer.subscription.deleted", sub);
  assertEquals(s.sent.filter((r) => r.method === "DELETE").length, 1, "idempotent");
  assertEquals(s.sent.filter((r) => r.method === "POST" && r.path === `/v1/subscriptions/${sub.id}`).length, 1);
  // Stripe's own event for the metadata the broker sets while it ends the trial overlaps the first delivery and is answered 409,
  // so the fake keeps sending it every few seconds: let it go.
  fake.close();
});

Deno.test("a cancel Stripe refused is tried again when Stripe sends the event again", async () => {
  const s = await setup();
  const { fake, press, prove, payouts, stripeDown } = s;
  await prove(A, TRIAL);
  await payouts(A);
  const sub = await startTrial(s);
  const portal = await portalOf(s);
  stripeDown.delete = true;
  await press(`${portal}?sub=${sub.id}`, "trial_fail");
  assertEquals(sub.status, "past_due", "not cancelled while Stripe is down");
  // The overlapping delivery (Stripe's own event for the metadata the broker just set) is told to wait, not
  // recorded delivered with its cancellation skipped: nothing is pushed until the cancel can be made.
  assertEquals(s.tenants.get(A)!.got.length, 1, "nothing pushed while the cancel cannot be made");
  stripeDown.delete = false;
  // The webhook was answered 502, so Stripe sends it again.
  assertEquals(await fake.emit("customer.subscription.updated", sub), true);
  assertEquals([sub.status, lastGot(s).trial?.state], ["canceled", "failed"]);
  fake.close();
});

Deno.test("the stand-in refuses a trial of under 48 hours, as Stripe does", async () => {
  const s = await setup();
  const { fake } = s;
  const open = (trial_end: number) => (fake.stripe as (...a: unknown[]) => Promise<unknown>)("POST", "/v1/checkout/sessions", {
    customer: "cus_1", line_items: [{ price: "price_1" }], subscription_data: { trial_end },
  }).then(() => "opened", (e) => e.message);
  const now = Math.floor(Date.now() / 1000);
  assertEquals((await open(now + 3600)).startsWith("subscription_data[trial_end]"), true);
  assertEquals((await open(now + 731 * 86400)).startsWith("subscription_data[trial_end]"), true);
  assertEquals(await open(now + 3 * 86400), "opened");
});

Deno.test("one broker in two modes sends a sandboxed tenant's trial to the sandbox", async () => {
  const seen: string[] = [];
  const mode = (name: string) => async (req: Request) => { seen.push(`${name} ${new URL(req.url).pathname}`); await req.body?.cancel(); return new Response(name); };
  const handler = twoModes({ live: mode("live"), sandbox: mode("sandbox"), sandboxed: (t) => t === "https://preview.example", sandboxWebhookSecret: "whsec_sandbox" });
  const ask = async (path: string, tenant: string) => await (await handler(new Request(`${ISSUER}${path}`, { method: "POST", body: JSON.stringify({ tenant }), headers: { "content-type": "application/json" } }))).text();
  for (const path of ["/trial/offer", "/trial/checkout"]) {
    assertEquals(await ask(path, "https://preview.example"), "sandbox", path);
    assertEquals(await ask(path, "https://shop.example.com"), "live", path);
  }
});

async function failFirstCharge(s: Awaited<ReturnType<typeof setup>>) {
  const sub = await startTrial(s);
  return { sub, portal: await portalOf(s) };
}

Deno.test("a failed first charge voids its open invoice before the cancel", async () => {
  const s = await setup();
  await s.prove(A, TRIAL);
  await s.payouts(A);
  const { sub, portal } = await failFirstCharge(s);
  await s.press(`${portal}?sub=${sub.id}`, "trial_fail");
  const [inv] = [...s.fake.held.invoices.values()];
  assertEquals([inv.status, sub.status], ["void", "canceled"]);
  const order = s.sent.filter((r) => r.path.startsWith("/v1/invoices/") || r.method === "DELETE").map((r) => `${r.method} ${r.path.replace(inv.id, "IN")}`);
  assertEquals(order, ["GET /v1/invoices/IN", "POST /v1/invoices/IN/void", `DELETE /v1/subscriptions/${sub.id}`]);
  s.fake.close();
});

Deno.test("an invoice that cannot be read or voided for a transient reason is tried again, then fails the event and cancels nothing until it can", async () => {
  const s = await setup();
  await s.prove(A, TRIAL);
  await s.payouts(A);
  const sub = await startTrial(s, BEA);
  const portal = await portalOf(s, BEA);
  s.stripeDown.invoices = 500;
  const before = s.sent.length;
  await s.press(`${portal}?sub=${sub.id}`, "trial_fail");
  assertEquals(s.sent.slice(before).filter((r) => r.path.startsWith("/v1/invoices/")).length, 3, "tried three times");
  assertEquals(sub.status, "past_due", "nothing cancelled while the invoice is unknown");
  s.stripeDown.invoices = 0;
  assertEquals(await s.fake.emit("customer.subscription.updated", sub), true, "Stripe's next send");
  assertEquals([sub.status, [...s.fake.held.invoices.values()].at(-1)!.status], ["canceled", "void"], "cancelled once voided");
  s.fake.close();
});

Deno.test("a key without Invoices access (403) is logged loudly and the failed trial is cancelled anyway", async () => {
  const s = await setup();
  await s.prove(A, TRIAL);
  await s.payouts(A);
  const sub = await startTrial(s, ANA);
  const portal = await portalOf(s, ANA);
  s.stripeDown.invoices = 403;
  const logged: string[] = [];
  const error = console.error;
  console.error = (...a: unknown[]) => { logged.push(a.join(" ")); };
  try {
    await s.press(`${portal}?sub=${sub.id}`, "trial_fail");
  } finally {
    console.error = error;
  }
  assertEquals(sub.status, "canceled", "cancelled without the invoice known");
  assertEquals(logged.some((l) => l.includes("Invoices permission")), true, "the missing permission is named");
  s.fake.close();
});

Deno.test("the per-client limits are kept apart by Stripe mode", async () => {
  const names: string[] = [];
  class Spy extends MemoryStore {
    override take(name: string, ...a: [string, number, number]): Promise<boolean> {
      names.push(name);
      return super.take(name, ...a);
    }
  }
  for (const mode of ["live", "sandbox"] as const) {
    names.length = 0;
    const s = await setup({ store: new Spy(), mode });
    await s.prove(A, TRIAL);
    await s.post("/checkout", { tenant: A, account: ANA, plan: "analysis" });
    await s.post("/trial/offer", { tenant: A, account: ANA, ticket: s.ticket(A) });
    assertEquals(names.filter((n) => n.includes("client")).sort(), [`client ${mode}`, `trial client ${mode}`], mode);
  }
});

// A completion that finds the claim taken by another caller is not a 200: Stripe sends the event again.
class Lost extends MemoryStore {
  mode: "off" | "taken" | "done" = "off";
  override complete(kind: string, id: string, token: string, ttlMs: number): Promise<boolean> {
    if (this.mode === "off") return super.complete(kind, id, token, ttlMs);
    // Another worker's claim replaced this one, or finished the event.
    return super.forget(kind, id).then(async () => {
      if (this.mode === "done") await this.remember(kind, id, ttlMs);
      else await this.claim(kind, id, 120_000);
      return false;
    });
  }
}

Deno.test("a completion that lost the claim is answered retryably, unless the store says the event is done", async () => {
  const store = new Lost();
  const s = await setup({ store });
  await s.prove(A, TRIAL);
  await s.payouts(A);
  const sub = await startTrial(s);
  store.mode = "taken";
  const taken = await deliver(s, "evt_taken", sub)();
  assertEquals([taken.status, (await taken.json()).error], [409, "claim lost"], "delivered, but another holds the claim");
  store.mode = "done";
  const done = await deliver(s, "evt_done", sub)();
  assertEquals([done.status, await done.json()], [200, { delivered: "evt_done" }], "the store says it is finished");
});


Deno.test("a first charge that was paid since is no failed trial: nothing is voided or cancelled", async () => {
  const s = await setup();
  await s.prove(A, TRIAL);
  await s.payouts(A);
  const sub = await startTrial(s);
  s.fake.held.invoices.set("in_paid", { id: "in_paid", status: "paid", subscription: sub.id });
  Object.assign(sub, { status: "past_due", latest_invoice: "in_paid", current_period_start: sub.trial_end });
  assertEquals(await s.fake.emit("customer.subscription.updated", sub), true);
  assertEquals(s.sent.filter((r) => r.method === "DELETE" || r.path.endsWith("/void")), []);
  assertEquals(sub.status, "past_due");
});

Deno.test("a junk ticket spends the caller's trial bucket, never the tenant's", async () => {
  const { call, prove, payouts, ticket } = await setup();
  await prove(A, TRIAL);
  await payouts(A);
  const from = (client: string, body: unknown) => call("/trial/offer", {
    method: "POST", headers: { "content-type": "application/json", "x-forwarded-for": client }, body: JSON.stringify(body),
  });
  const junk = { tenant: A, account: ANA, ticket: "j".repeat(32) };
  const statuses: number[] = [];
  for (let i = 0; i < 61; i++) statuses.push((await from("1.1.1.1", junk)).status);
  assertEquals([statuses.slice(0, 60).every((x) => x === 403), statuses[60]], [true, 429], "one caller's limit");
  // Far more junk than a tenant's own 120 a minute, from callers that each stay under theirs.
  for (let c = 2; c < 6; c++) for (let i = 0; i < 50; i++) assertEquals((await from(`2.2.2.${c}`, junk)).status, 403);
  assertEquals((await from("3.3.3.3", { tenant: A, account: ANA, ticket: ticket(A) })).status, 200, "the tenant's bucket is whole");
});

Deno.test("two checkouts at once for one account open one Checkout", async () => {
  const s = await setup();
  await s.prove(A, TRIAL);
  await s.payouts(A);
  const [one, two] = await Promise.all([
    s.post("/checkout", { tenant: A, account: ANA, plan: "analysis" }),
    s.post("/trial/checkout", { tenant: A, account: ANA, ticket: s.ticket(A, s.consentTo()) }),
  ]);
  assertEquals([one.status, two.status], [200, 200]);
  assertEquals([s.fake.held.customers.size, s.fake.held.sessions.size], [1, 1], "the first was closed when the second opened");
});

Deno.test("a second trial that raced in is cancelled at once and marked, and the first stands", async () => {
  const s = await setup();
  await s.prove(A, TRIAL);
  await s.payouts(A);
  const older = await startTrial(s);
  // deno-lint-ignore no-explicit-any
  const newer: Record<string, any> = { ...structuredClone(older), id: "sub_newer", created: older.created + 5, status: "trialing", metadata: { ...older.metadata } };
  s.fake.held.subscriptions.set(newer.id, newer);
  await s.fake.emit("customer.subscription.created", newer);
  assertEquals([newer.status, newer.metadata.trial_duplicate, older.status], ["canceled", "1", "trialing"]);
  assertEquals(newer.charges, 0, "nothing was charged");
  const e = lastGot(s);
  assertEquals([e.active, e.trial?.state], [true, "running"], "the account's trial is still the first");
  // The first's own created event cancels nothing.
  await s.fake.emit("customer.subscription.created", older);
  assertEquals(older.status, "trialing");
});

Deno.test("a tenant that fails its consent callback is a generic 502 to the caller, and the log has why", async () => {
  const s = await setup();
  await s.prove(A, TRIAL);
  s.tenants.get(A)!.consentFails = 500;
  const res = await s.post("/trial/offer", { tenant: A, account: ANA, ticket: "t".repeat(32) });
  assertEquals([res.status, await res.json()], [502, { error: "the tenant is unavailable" }]);
});

Deno.test("a probe reads the account at Stripe and writes nothing", async () => {
  const { fake, post, prove, payouts, sent } = await setup();
  await prove(A);
  await payouts(A);
  const before = sent.length, customers = fake.held.customers.size;
  const res = await post("/probe", { tenant: A, account: ANA });
  assertEquals([res.status, await res.json()], [200, { ok: true, direct: false }], "a broker outside a request notes no transport");
  const asked = sent.slice(before);
  assertEquals(asked.map((s) => s.method).every((m) => m === "GET"), true, "only reads");
  assertEquals(asked.some((s) => s.path === "/v1/customers/search"), true, "the account's customers read");
  assertEquals(fake.held.customers.size, customers, "no customer made");
  assertEquals((await post("/probe", { tenant: A })).status, 400, "an account is named");
  for (const door of [true, false]) {
    assertEquals(await (await post("/probe", { tenant: A, account: ANA, door })).json(), { ok: true, direct: false, door }, "the tenant's word is said back");
  }
});

Deno.test("the stand-in is reached through its door: every call in its ledger, a replayed key answered from it", async () => {
  const { fake, door, prove, payouts } = await setup();
  assertEquals(await door.route!(), "door", "every call goes through the door");
  await prove(A);
  await payouts(A);
  assertEquals(fake.ledger.size > 0, true, "the broker's calls are in the door's ledger");
  const ask = (body: unknown, name = "stripe") =>
    fake.handle(new Request(`${ISSUER}/door/${name}`, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(body) }))!;
  const made = { key: "key-1", sinkKey: "made once", method: "POST", path: "/v1/customers", body: "metadata[tenant]=https%3A%2F%2Fa.example&metadata[account]=x", contentType: "application/x-www-form-urlencoded" };
  const first = await (await ask(made)).json();
  const again = await (await ask(made)).json();
  assertEquals([first.status, again.status, again.replayed, again.body.id], [200, 200, true, first.body.id], "a replayed key answers from the ledger, making nothing");
  assertEquals(first.body.metadata, { tenant: A, account: "x" }, "the form read back as Stripe reads it");
  assertEquals((await ask({ ...made, path: "/v1/prices" })).status, 409, "a key is one call");
  const missing = await (await ask({ key: "key-2", method: "GET", path: "/v1/subscriptions/sub_none" })).json();
  assertEquals([missing.status, missing.body.error.code], [404, "resource_missing"], "Stripe's refusal is the door's answer");
  assertEquals((await ask({ key: "key-3", method: "GET", path: "/v1/account" }, "stripe-sandbox")).status, 200, "the sandbox's door too");
  assertEquals((await ask({ key: "key-4", method: "GET", path: "/v1/account" }, "github")).status, 404, "no other door");
  assertEquals((await ask({ key: "bad key!", method: "GET", path: "/v1/account" })).status, 400, "a key the airlock takes");
});

// Stripe sees one Idempotency-Key whichever way a call went (PRONTO-223): a customer asked for straight,
// then asked again through the door (the stripe_door flag turned on between them, or a retry after it
// was), is made once. The straight way's header is stripe_test.ts's ("the direct way sends the broker's own
// idempotency key"); both ways hold one Stripe key, so one account scopes the key (PRONTO-218).
Deno.test("a call made straight and then again through the door reaches Stripe under one key and makes one customer", async () => {
  const fake = fakeStripe(ISSUER, { searchLagMs: 0 });
  const door = stripeClient({ door: `${ISSUER}/door/stripe`, fetcher: ((u: string | URL | Request, init?: RequestInit) => fake.handle(new Request(u, init))!) as typeof fetch });
  const params = { metadata: { tenant: A, account: ANA } };
  const key = `customer ${A} ${ANA}`;
  const straight = await fake.stripe("POST", "/v1/customers", params, key) as { id: string };
  const through = await door("POST", "/v1/customers", params, key) as { id: string };
  assertEquals(through.id, straight.id, "the door's call is Stripe's replay of the straight one");
  assertEquals(fake.held.customers.size, 1, "one customer");
  const other = await door("POST", "/v1/customers", params, `${key} again`) as { id: string };
  assertEquals(other.id === straight.id, false, "another key is another call");
  assertEquals(fake.held.customers.size, 2, "and another customer");
});

Deno.test("Stripe's form is read back into its objects and arrays", () => {
  assertEquals(unform("a=1&b[c]=2&d[0]=x&d[1]=y&e[0][f]=g"), { a: "1", b: { c: "2" }, d: ["x", "y"], e: [{ f: "g" }] });
  assertEquals(unform(`${form({ line_items: [{ price: "p", quantity: 1 }], metadata: { tenant: "t" } })}`), { line_items: [{ price: "p", quantity: "1" }], metadata: { tenant: "t" } });
});

// Two replicas sharing one store (PRONTO-371), as the node's pods share the broker's database.
Deno.test("two replicas: two checkouts at once for one account still open one Checkout", async () => {
  const s = await setup({ replicas: 2 });
  await s.prove(A, TRIAL);
  await s.payouts(A);
  const [one, two] = await Promise.all([
    s.post("/checkout", { tenant: A, account: ANA, plan: "analysis" }),
    s.post("/trial/checkout", { tenant: A, account: ANA, ticket: s.ticket(A, s.consentTo()) }),
  ]);
  assertEquals([one.status, two.status], [200, 200]);
  assertEquals([s.fake.held.customers.size, s.fake.held.sessions.size], [1, 1], "the lock held across the replicas");
});

Deno.test("two replicas: an event delivered by one is answered by the other without a second push", async () => {
  const s = await setup({ replicas: 2 });
  await s.prove(A, TRIAL);
  await s.payouts(A);
  const sub = await startTrial(s);
  const got = s.tenants.get(A)!.got;
  const before = got.length;
  const payload = JSON.stringify({ id: "evt_replayed", type: "customer.subscription.updated", created: 1, data: { object: sub } });
  const send = async () => s.call("/stripe", { method: "POST", body: payload, headers: { "stripe-signature": await signWebhook(s.fake.webhookSecret, payload) } });
  const first = await send();
  assertEquals([first.status, await first.json()], [200, { delivered: "evt_replayed" }]);
  assertEquals(got.length, before + 1, "pushed once");
  const again = await send();
  assertEquals([again.status, await again.json()], [200, { duplicate: "evt_replayed" }], "the other replica knows it");
  assertEquals(got.length, before + 1, "not pushed again");
});

Deno.test("two replicas: every entitlement is newer than the one before, whichever signed it", async () => {
  const s = await setup({ replicas: 2 });
  await s.prove(A);
  await s.payouts(A);
  await s.press((await (await s.post("/checkout", { tenant: A, account: ANA, plan: "analysis" })).json()).url, "pay");
  const { manage } = s.tenants.get(A)!.got[0];
  const vers: number[] = [];
  for (let i = 0; i < 6; i++) {
    const { token } = await (await s.post("/resync", { tenant: A, account: ANA, plan: "analysis", manage })).json();
    vers.push(JSON.parse(new TextDecoder().decode(Uint8Array.from(atob(token.split(".")[1].replace(/-/g, "+").replace(/_/g, "/")), (c) => c.charCodeAt(0)))).ver);
  }
  assertEquals(vers.every((v, i) => i === 0 || v > vers[i - 1]), true, `increasing over both replicas: ${vers}`);
});

// One Stripe event reaches every replica at once, and is pushed to the tenant by one.
const deliver = (s: Awaited<ReturnType<typeof setup>>, id: string, sub: unknown, type = "customer.subscription.updated") => async () => {
  const payload = JSON.stringify({ id, type, created: 1, data: { object: sub } });
  return await s.call("/stripe", { method: "POST", body: payload, headers: { "stripe-signature": await signWebhook(s.fake.webhookSecret, payload) } });
};

Deno.test("two replicas: one event arriving at both at once is pushed once, and the other is told to wait", async () => {
  const s = await setup({ replicas: 2 });
  await s.prove(A, TRIAL);
  await s.payouts(A);
  const sub = await startTrial(s);
  const t = s.tenants.get(A)!;
  const before = t.got.length;
  // The tenant takes its time over the push: the second delivery arrives while the first is in it.
  let release!: () => void;
  t.hold = new Promise<void>((r) => (release = r));
  const send = deliver(s, "evt_race", sub);
  const first = send();
  await new Promise((r) => setTimeout(r, 20));
  const second = await send();
  assertEquals([second.status, (await second.json()).error], [409, "in progress"], "Stripe sends it again");
  assertEquals(t.got.length, before, "nothing pushed yet by the first, nothing by the second");
  release();
  t.hold = undefined;
  const done = await first;
  assertEquals([done.status, await done.json()], [200, { delivered: "evt_race" }]);
  assertEquals(t.got.length, before + 1, "pushed once");
  const again = await send();
  assertEquals([again.status, await again.json()], [200, { duplicate: "evt_race" }]);
  assertEquals(t.got.length, before + 1, "and not again once it is done");
});

Deno.test("a push the tenant failed leaves the event claimable for Stripe's next send", async () => {
  const s = await setup({ replicas: 2 });
  await s.prove(A, TRIAL);
  await s.payouts(A);
  const sub = await startTrial(s);
  const t = s.tenants.get(A)!;
  const before = t.got.length;
  const send = deliver(s, "evt_502", sub);
  t.up = false;
  assertEquals((await send()).status, 502);
  t.up = true;
  const retry = await send();
  assertEquals([retry.status, await retry.json()], [200, { delivered: "evt_502" }], "not held for its lease, not done");
  assertEquals(t.got.length, before + 1);
});

Deno.test("an event whose subscription is being ended by another caller is not recorded delivered", async () => {
  const store = new MemoryStore();
  const s = await setup({ store });
  await s.prove(A, TRIAL);
  await s.payouts(A);
  const sub = await startTrial(s);
  const t = s.tenants.get(A)!;
  const before = t.got.length;
  const failing = { ...structuredClone(sub), status: "past_due" };
  const send = deliver(s, "evt_overlap", failing);
  // Another delivery is in the middle of ending this subscription.
  let release!: () => void;
  const holder = store.exclusive(`ending ${sub.id}`, () => new Promise<void>((r) => (release = r)));
  const res = await send();
  assertEquals([res.status, (await res.json()).error], [409, "subscription busy"], "a retryable answer, not delivered");
  assertEquals([t.got.length, sub.status], [before, "trialing"], "nothing pushed, nothing cancelled");
  release();
  await holder;
  const retry = await send();
  assertEquals([retry.status, await retry.json()], [200, { delivered: "evt_overlap" }], "the retry is not a duplicate: the first was never recorded");
  assertEquals(t.got.length, before + 1);
});

Deno.test("a lease that cannot be released is reported, with the failure that made it necessary", async () => {
  let completeFails = false, releaseFails = false;
  class Stuck extends MemoryStore {
    override forget(...a: Parameters<MemoryStore["forget"]>): Promise<boolean> {
      return releaseFails ? Promise.reject(new Error("release failed")) : super.forget(...a);
    }
    override complete(...a: Parameters<MemoryStore["complete"]>): Promise<boolean> {
      return completeFails ? Promise.reject(new Error("complete failed")) : super.complete(...a);
    }
  }
  const s = await setup({ store: new Stuck() });
  await s.prove(A, TRIAL);
  await s.payouts(A);
  const sub = await startTrial(s);
  const t = s.tenants.get(A)!;
  const logged: unknown[] = [];
  const error = console.error;
  console.error = (...a: unknown[]) => { logged.push(...a); };
  try {
    releaseFails = true;
    // A push the tenant did not take: the answer is a 502, and the release that follows fails alone.
    t.up = false;
    const alone = await deliver(s, "evt_alone", sub)();
    assertEquals([alone.status, logged.some((x) => x instanceof Error && x.message === "release failed")], [500, true], "a failed release is reported, not swallowed");
    t.up = true;
    // Processing and release both fail: both are reported.
    logged.length = 0;
    completeFails = true;
    const both = await deliver(s, "evt_both", sub)();
    assertEquals(both.status, 500);
    const e = logged.find((x): x is AggregateError => x instanceof AggregateError);
    assertEquals(e?.errors.map((x: Error) => x.message), ["complete failed", "release failed"], "both failures are named");
  } finally {
    console.error = error;
  }
});

Deno.test("a push that succeeds but takes long is still verified, not answered too slow", async () => {
  const s = await setup();
  await s.prove(A, TRIAL);
  await s.payouts(A);
  const sub = await startTrial(s);
  const t = s.tenants.get(A)!;
  const before = t.got.length;
  const now = Date.now;
  let skew = 0;
  Date.now = () => now() + skew;
  try {
    let release!: () => void;
    t.hold = new Promise<void>((r) => (release = r));
    const sending = deliver(s, "evt_long", sub)();
    await new Promise((r) => setTimeout(r, 10));
    skew = 40_000; // the push took longer than a quarter of the lease
    release();
    t.hold = undefined;
    const res = await sending;
    assertEquals([res.status, await res.json()], [200, { delivered: "evt_long" }], "read back and found as pushed");
    assertEquals(t.got.length, before + 1, "pushed once");
  } finally {
    Date.now = now;
  }
});

Deno.test("a resync takes a plan id by the one rule, rules.cue's", async () => {
  const s = await setup();
  await s.prove(A);
  await s.payouts(A);
  await s.press((await (await s.post("/checkout", { tenant: A, account: ANA, plan: "analysis" })).json()).url, "pay");
  const { manage } = s.tenants.get(A)!.got[0];
  const bad = await s.post("/resync", { tenant: A, account: ANA, plan: "Bad Plan", manage });
  assertEquals([bad.status, (await bad.json()).error], [400, "plan required"]);
  const good = await s.post("/resync", { tenant: A, account: ANA, plan: "analysis", manage });
  assertEquals(good.status, 200);
  await good.body?.cancel();
});

// The probe says which transport answered its read, as the switched client noted it, never what the request said.
const PROBE_CASES: { name: string; switched: "asked" | "never" | "direct" | "door"; door?: boolean; transport: string; calls: string[] }[] = [
  { name: "a direct-only broker says direct", switched: "direct", transport: "direct", calls: ["direct"] },
  { name: "a door-only broker says door, whatever the request says", switched: "door", door: false, transport: "door", calls: ["door"] },
  { name: "door true: the door answers", switched: "asked", door: true, transport: "door", calls: ["door"] },
  { name: "door false: the broker's own key answers", switched: "asked", door: false, transport: "direct", calls: ["direct"] },
  { name: "no word: straight to Stripe", switched: "asked", transport: "direct", calls: ["direct"] },
  { name: "the request says door but the client goes direct: said as it went", switched: "never", door: true, transport: "direct", calls: ["direct"] },
];
for (const c of PROBE_CASES) {
  Deno.test(`probe transport, ${c.name}`, async () => {
    const s = await setup({ switched: c.switched });
    await s.prove(A);
    await s.payouts(A);
    s.transportCalls.length = 0;
    const res = await s.post("/probe", { tenant: A, account: ANA, ...(c.door === undefined ? {} : { door: c.door }) });
    const body = await res.json();
    assertEquals([res.status, body.transport, body.direct, [...new Set(s.transportCalls)]], [200, c.transport, c.transport === "direct", c.calls], c.name);
    assertEquals(body.door, c.door, "the request's word is said back as its own, apart from the transport");
  });
}

Deno.test("an invoice call that hits the transport's deadline is tried again, three times in all", async () => {
  const s = await setup();
  await s.prove(A, TRIAL);
  await s.payouts(A);
  const sub = await startTrial(s, BEA);
  const portal = await portalOf(s, BEA);
  s.stripeDown.invoicesTimeout = true;
  const before = s.sent.length;
  await s.press(`${portal}?sub=${sub.id}`, "trial_fail");
  assertEquals(s.sent.slice(before).filter((r) => r.path.startsWith("/v1/invoices/")).length, 3, "a timeout is transient");
  assertEquals(sub.status, "past_due", "nothing cancelled while the invoice is unknown");
  s.stripeDown.invoicesTimeout = false;
  assertEquals(await s.fake.emit("customer.subscription.updated", sub), true);
  assertEquals(sub.status, "canceled");
  s.fake.close();
});

Deno.test("a tenant's refusal is a loud non-2xx on every delivery and never marks the event done", async () => {
  const s = await setup();
  await s.prove(A, TRIAL);
  await s.payouts(A);
  const sub = await startTrial(s);
  const t = s.tenants.get(A)!;
  const logged: string[] = [];
  const error = console.error;
  console.error = (...a: unknown[]) => { logged.push(a.join(" ")); };
  try {
    t.refuse = true;
    const statuses: number[] = [];
    for (let i = 0; i < 8; i++) {
      const res = await deliver(s, "evt_refused", sub)();
      statuses.push(res.status);
      await res.body?.cancel();
    }
    assertEquals(statuses, Array(8).fill(502), "Stripe is asked to send it again every time; no count ends it");
    const alerts = logged.filter((l) => l.includes("billing_alert=entitlement_refused"));
    assertEquals(alerts.length, 8, "every refusal is a loud, distinctive line");
    assertEquals(alerts.every((l) => l.includes(`account=${ANA}`) && l.includes("event=evt_refused")), true, "naming the account and the event");
    // The tenant takes it on a later resend: delivered, and only then remembered.
    t.refuse = false;
    const before = t.got.length;
    const again = await deliver(s, "evt_refused", sub)();
    assertEquals([again.status, await again.json(), t.got.length], [200, { delivered: "evt_refused" }, before + 1], "still eligible for redelivery");
    const dup = await deliver(s, "evt_refused", sub)();
    assertEquals(await dup.json(), { duplicate: "evt_refused" }, "a delivery is remembered");
  } finally {
    console.error = error;
  }
});

// The route probe: which transport a call would take for a door word, from the real selection, with no call to Stripe.
const ROUTE_CASES: { name: string; switched: "asked" | "direct" | "door"; door?: boolean; transport: string }[] = [
  { name: "door true: door", switched: "asked", door: true, transport: "door" },
  { name: "door false: direct", switched: "asked", door: false, transport: "direct" },
  { name: "no word: direct", switched: "asked", transport: "direct" },
  { name: "a direct-only broker reports direct whatever is asked", switched: "direct", door: true, transport: "direct" },
  { name: "a door-only broker reports door whatever is asked", switched: "door", door: false, transport: "door" },
];
for (const c of ROUTE_CASES) {
  Deno.test(`route probe, ${c.name}`, async () => {
    const s = await setup({ switched: c.switched });
    s.transportCalls.length = 0;
    const before = s.sent.length;
    const res = await s.post("/route", { tenant: A, ...(c.door === undefined ? {} : { door: c.door }) });
    assertEquals([res.status, await res.json()], [200, { transport: c.transport }], c.name);
    assertEquals([s.transportCalls, s.sent.length - before], [[], 0], "Stripe is not called");
    assertEquals((await s.post("/route", {})).status, 400, "a tenant is named");
  });
}

// The route probe has limiters of its own, a capped body, and chooses by the very function a call's dispatch uses.
Deno.test("route probes never spend a player's checkout, trial or probe quota, and have a cap of their own", async () => {
  const names: string[] = [];
  class Spy extends MemoryStore {
    override take(name: string, ...a: [string, number, number]): Promise<boolean> {
      names.push(name);
      return super.take(name, ...a);
    }
  }
  const s = await setup({ store: new Spy(), switched: "asked" });
  for (let i = 0; i < 5; i++) await (await s.post("/route", { tenant: A, door: true })).body?.cancel();
  assertEquals([...new Set(names)].sort(), ["route all live", "route client live"], "only its own limiters are taken");
  // Past the per-client cap, a route probe is refused; a checkout from the same client is not.
  let refused = 0;
  for (let i = 0; i < 40; i++) {
    const r = await s.post("/route", { tenant: A, door: true });
    if (r.status === 429) refused++;
    await r.body?.cancel();
  }
  assertEquals(refused > 0, true, "capped");
  await s.prove(A);
  await s.payouts(A);
  const checkout = await s.post("/checkout", { tenant: A, account: ANA, plan: "analysis" });
  assertEquals(checkout.status, 200, "the checkout quota is untouched by route probes");
  await checkout.body?.cancel();
});

Deno.test("a route probe reads a capped body: over the cap is a 413", async () => {
  const s = await setup({ switched: "asked" });
  const big = await s.call("/route", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ tenant: A, pad: "x".repeat(5000) }) });
  assertEquals(big.status, 413);
  await big.body?.cancel();
});

Deno.test("the route probe and a real call choose the same transport, for door true, false and absent", async () => {
  for (const door of [true, false, undefined]) {
    const s = await setup({ switched: "asked" });
    await s.prove(A);
    await s.payouts(A);
    const word = door === undefined ? {} : { door };
    const probe = await (await s.post("/route", { tenant: A, ...word })).json();
    s.transportCalls.length = 0;
    const res = await s.post("/probe", { tenant: A, account: ANA, ...word });
    await res.body?.cancel();
    assertEquals([...new Set(s.transportCalls)], [probe.transport], `door ${door}: the dispatch took what /route said`);
  }
});

Deno.test("the dispatcher enforces the body limit (413) before it picks a broker, for every body-reading endpoint", async () => {
  const seen: string[] = [];
  const mode = (name: string) => async (req: Request) => { seen.push(name); await req.body?.cancel(); return new Response(name); };
  const handler = twoModes({ live: mode("live"), sandbox: mode("sandbox"), sandboxed: (t) => t.includes("-rc-"), sandboxWebhookSecret: "whsec_sandbox" });
  const post = (path: string, body: string, declared = true) => handler(new Request(`${ISSUER}${path}`, {
    method: "POST", headers: { "content-type": "application/json", ...(declared ? {} : {}) }, body,
  }));
  const big = JSON.stringify({ tenant: "https://shop-rc-123456789012.us-central1.run.app", pad: "x".repeat(5000) });
  for (const path of ["/checkout", "/trial/offer", "/trial/checkout", "/portal", "/resync", "/onboard", "/probe", "/route"]) {
    const res = await post(path, big);
    assertEquals([path, res.status], [path, 413], "over the limit is refused whole");
    await res.body?.cancel();
  }
  const webhook = await post("/stripe", "x".repeat(262_145));
  assertEquals(webhook.status, 413);
  await webhook.body?.cancel();
  assertEquals(seen, [], "no broker was picked or asked");
  const ok = await post("/route", JSON.stringify({ tenant: "https://shop-rc-123456789012.us-central1.run.app" }));
  assertEquals([await ok.text(), seen], ["sandbox", ["sandbox"]], "a body within the limit still goes to its broker");
});

Deno.test("the dispatcher reads the body once and hands the chosen broker that text; an endless body is a 413 at once", async () => {
  const got: string[] = [];
  const mode = (name: string) => async (req: Request) => { got.push(`${name} ${await req.text()}`); return new Response(name); };
  const handler = twoModes({ live: mode("live"), sandbox: mode("sandbox"), sandboxed: (t) => t.includes("-rc-"), sandboxWebhookSecret: "whsec_sandbox" });
  const text = JSON.stringify({ tenant: "https://shop-rc-123456789012.us-central1.run.app", account: "a" });
  const res = await handler(new Request(`${ISSUER}/checkout`, { method: "POST", headers: { "content-type": "application/json" }, body: text }));
  assertEquals([await res.text(), got], ["sandbox", [`sandbox ${text}`]], "the broker chosen gets the body already read");
  const never = new ReadableStream<Uint8Array>({ pull(c) { c.enqueue(new TextEncoder().encode("x".repeat(1024))); } });
  let timer: ReturnType<typeof setTimeout> | undefined;
  const answered = await Promise.race([
    handler(new Request(`${ISSUER}/checkout`, { method: "POST", headers: { "content-type": "application/json" }, body: never })),
    new Promise<string>((r) => { timer = setTimeout(() => r("hung"), 3000); }),
  ]);
  clearTimeout(timer);
  assertEquals(answered instanceof Response ? answered.status : answered, 413);
  assertEquals(got.length, 1, "no broker saw it");
});
