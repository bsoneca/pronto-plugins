// The broker end to end, against the stand-in for Stripe and two tenants this
// test serves: an author proves an origin and sets up payouts, an account
// subscribes and its tenant alone is told, manages it with the token its
// tenant was given, and lapses when it cancels or a payment fails; one
// tenant's claim, customers and tokens are nothing to another.
import { Refused } from "../shared.ts";
import { brokerKeys, type Entitlement, verifyEntitlement } from "../entitlement.ts";
import { broker, twoModes } from "./main.ts";
import { checkoutLocale, ownerOf, tenantOf } from "./core.ts";
import { fakeStripe } from "./fake.ts";
import { signWebhook } from "./stripe.ts";

function assertEquals(a: unknown, b: unknown, m = "") {
  if (JSON.stringify(a) !== JSON.stringify(b)) throw new Error(`${m} expected ${JSON.stringify(b)}, got ${JSON.stringify(a)}`);
}

const ISSUER = "http://localhost:28463";
const A = "https://a.example", B = "https://b.example";
const ANA = "00000000-0000-4000-8000-00000000000a";
const BEA = "00000000-0000-4000-8000-00000000000b";
const PLANS = { analysis: { name: "Analysis", interval: "month", prices: { usd: 499, brl: 1990 } } };

async function setup(o: { searchLagMs?: number; issuer?: string } = {}) {
  const fake = fakeStripe(ISSUER, { searchLagMs: o.searchLagMs ?? 0 });
  // Every request the broker makes to Stripe, as the stand-in is asked it.
  const sent: { method: string; path: string }[] = [];
  const stripe = ((method: string, path: string, ...rest: unknown[]) => {
    sent.push({ method, path });
    return (fake.stripe as (...a: unknown[]) => unknown)(method, path, ...rest);
  }) as typeof fake.stripe;
  const tenants = new Map<string, { doc?: unknown; up: boolean; got: Entitlement[]; hold?: Promise<void> }>([
    [A, { up: true, got: [] }], [B, { up: true, got: [] }],
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
  const prove = async (tenant: string) => {
    const secret = `${tenant} author's secret, long enough`;
    secrets.set(tenant, secret);
    tenants.get(tenant)!.doc = { owner: await ownerOf(secret), plans: PLANS };
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
  return { fake, sent, tenants, call, post, press, prove, payouts, secrets };
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
