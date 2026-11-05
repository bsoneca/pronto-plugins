// The broker end to end, against the stand-in for Stripe and two tenants this
// test serves: an author proves an origin and sets up payouts, an account
// subscribes and its tenant alone is told, manages it with the token its
// tenant was given, and lapses when it cancels or a payment fails; one
// tenant's claim, customers and tokens are nothing to another.
import { Refused } from "../shared.ts";
import { brokerKeys, type Entitlement, verifyEntitlement } from "../entitlement.ts";
import { broker, twoModes } from "./main.ts";
import { chargesAt, checkoutLocale, type Consent, ownerOf, tenantOf } from "./core.ts";
import { fakeStripe } from "./fake.ts";
import { signWebhook, StripeError } from "./stripe.ts";

function assertEquals(a: unknown, b: unknown, m = "") {
  if (JSON.stringify(a) !== JSON.stringify(b)) throw new Error(`${m} expected ${JSON.stringify(b)}, got ${JSON.stringify(a)}`);
}

const ISSUER = "http://localhost:28463";
const A = "https://a.example", B = "https://b.example";
const ANA = "00000000-0000-4000-8000-00000000000a";
const BEA = "00000000-0000-4000-8000-00000000000b";
const PLANS = { analysis: { name: "Analysis", interval: "month", prices: { usd: 499, brl: 1990 } } };
const TRIAL = { months: 3, plans: ["analysis"], remindDays: 7 };

async function setup(o: { searchLagMs?: number; issuer?: string } = {}) {
  const fake = fakeStripe(ISSUER, { searchLagMs: o.searchLagMs ?? 0 });
  // Every request the broker makes to Stripe, as the stand-in is asked it.
  const sent: { method: string; path: string; params?: Record<string, unknown> }[] = [];
  // What Stripe should refuse, for a test of the broker's retries.
  const stripeDown = { delete: false };
  const stripe = ((method: string, path: string, ...rest: unknown[]) => {
    sent.push({ method, path, params: rest[0] as Record<string, unknown> | undefined });
    if (method === "DELETE" && stripeDown.delete) return Promise.reject(new StripeError(500, "api_error", "Stripe is down"));
    return (fake.stripe as (...a: unknown[]) => unknown)(method, path, ...rest);
  }) as typeof fake.stripe;
  const tenants = new Map<string, { doc?: unknown; up: boolean; got: Entitlement[]; hold?: Promise<void>; tickets: Map<string, Consent> }>([
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
        t.got.push(e);
        return new Response(null, { status: 204 });
      } catch (e) {
        if (e instanceof Refused) return new Response(e.message, { status: 400 });
        throw e;
      }
    }
    // A ticket the tenant minted gives back its consent once, and is unknown after.
    if (url.pathname === "/billing/trial/consent") {
      const { account, ticket } = JSON.parse(String(init?.body));
      const consent = account === ANA || account === BEA ? t.tickets.get(ticket) : undefined;
      t.tickets.delete(ticket);
      return consent ? Response.json(consent) : new Response("", { status: 404 });
    }
    return new Response("", { status: 404 });
  }) as typeof fetch;
  const handler = await broker({ issuer: ISSUER, secret: "s".repeat(32), stripe, webhookSecret: fake.webhookSecret, fetcher, cacheMs: 0, feePercent: 10 });
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
  return { fake, sent, stripeDown, tenants, call, post, press, prove, payouts, secrets, ticket, consentTo, OFFER };
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
  assertEquals(lastGot(s).active, false, "past due holds nothing meanwhile");
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
