// The broker's decisions, apart from its network.
import {
  chargesAt, checkoutSession, consentChecked, derivedKey, entitlementClaims, entitlementOf, firstChargeFailed, lookupKeyOf, manageTokenOf,
  parsePublished, returnTo, type Subscription, trialOf, trialSpent,
} from "./core.ts";
import { form, signWebhook, STRIPE_V2_VERSION, STRIPE_VERSION, stripe, webhookSigned } from "./stripe.ts";

function assertEquals(a: unknown, b: unknown, m = "") {
  if (JSON.stringify(a) !== JSON.stringify(b)) throw new Error(`${m} expected ${JSON.stringify(b)}, got ${JSON.stringify(a)}`);
}

const A = "https://a.example", B = "https://b.example";

Deno.test("a page goes back only to a path on its own origin", () => {
  assertEquals(returnTo(A, undefined), `${A}/`);
  assertEquals(returnTo(A, "/review?game=1"), `${A}/review?game=1`);
  for (const bad of ["//evil.example/x", "https://evil.example/", "review", "/\\evil.example", "/a b", 7]) assertEquals(returnTo(A, bad), null, String(bad));
});

Deno.test("a manage token is one account's of one tenant", async () => {
  const m = await derivedKey("s".repeat(32), "billing manage");
  const acct = "00000000-0000-4000-8000-000000000001";
  assertEquals((await manageTokenOf(m, A, acct)) === (await manageTokenOf(m, B, acct)), false, "one uuid in two tenants");
  const other = await derivedKey("t".repeat(32), "billing manage");
  assertEquals((await manageTokenOf(m, A, acct)) === (await manageTokenOf(other, A, acct)), false, "another broker's");
});

Deno.test("a published document names its plans and their prices", () => {
  const O = "o".repeat(43);
  const ok = parsePublished({ owner: O, plans: { analysis: { name: "Analysis", interval: "month", prices: { usd: 499, brl: 1990 } } } });
  assertEquals(ok.ok && ok.published.plans.analysis.prices, { usd: 499, brl: 1990 });
  for (const [doc, why] of [
    [{ plans: { a: { name: "A", interval: "month", prices: { usd: 499 } } } }, "no owner"],
    [{ owner: O, plans: {} }, "no plans"],
    [{ owner: O, plans: { A: { name: "A", interval: "month", prices: { usd: 499 } } } }, "plan A: a lowercase name"],
    [{ owner: O, plans: { a: { name: "A", interval: "week", prices: { usd: 499 } } } }, "plan a: interval month or year"],
    [{ owner: O, plans: { a: { name: "A", interval: "month", prices: { xyz: 499 } } } }, "plan a: currency xyz"],
    [{ owner: O, plans: { a: { name: "A", interval: "month", prices: { usd: 4.99 } } } }, "plan a: usd in minor units, 50 to 1000000"],
    [{ owner: O, plans: { a: { name: "A", interval: "month", prices: {} } } }, "plan a: a price"],
  ] as const) {
    const r = parsePublished(doc);
    assertEquals(r.ok ? "" : r.error, why);
  }
});

Deno.test("a plan's new price is a new Stripe price; the same price, the same one", async () => {
  const p = { name: "Analysis", interval: "month" as const, prices: { usd: 499, brl: 1990 } };
  assertEquals(await lookupKeyOf(A, "analysis", p), await lookupKeyOf(A, "analysis", { ...p, prices: { brl: 1990, usd: 499 } }));
  assertEquals((await lookupKeyOf(A, "analysis", p)) === (await lookupKeyOf(A, "analysis", { ...p, prices: { usd: 599, brl: 1990 } })), false);
  assertEquals((await lookupKeyOf(A, "analysis", p)) === (await lookupKeyOf(B, "analysis", p)), false);
});

Deno.test("an account holds a plan while any of its subscriptions to it is paid", () => {
  const md = { tenant: A, account: "x", plan: "analysis" };
  const s = (status: string, end: number, m = md) => ({ id: status, status, current_period_end: end, metadata: m });
  assertEquals(entitlementOf([s("active", 100)], A, "x", "analysis"), { active: true, through: 100 });
  assertEquals(entitlementOf([s("trialing", 100), s("active", 200)], A, "x", "analysis"), { active: true, through: 200 });
  for (const lapsed of ["past_due", "unpaid", "canceled", "paused", "incomplete", "incomplete_expired"]) {
    assertEquals(entitlementOf([s(lapsed, 100)], A, "x", "analysis"), { active: false, through: 0 }, lapsed);
  }
  // A cancelled subscription beside a paid one leaves the plan held.
  assertEquals(entitlementOf([s("canceled", 300), s("active", 200)], A, "x", "analysis"), { active: true, through: 200 });
  // Another tenant's, account's or plan's subscription holds nothing here.
  assertEquals(entitlementOf([s("active", 100, { ...md, tenant: B }), s("active", 100, { ...md, account: "y" }), s("active", 100, { ...md, plan: "p" })], A, "x", "analysis"), { active: false, through: 0 });
});

Deno.test("Stripe's webhook signature: its secret, its body, its time", async () => {
  const now = 1_800_000_000;
  const h = await signWebhook("whsec_a", "{}", now);
  assertEquals(await webhookSigned("whsec_a", "{}", h, 300, now), true);
  assertEquals(await webhookSigned("whsec_b", "{}", h, 300, now), false, "another secret");
  assertEquals(await webhookSigned("whsec_a", "{ }", h, 300, now), false, "another body");
  assertEquals(await webhookSigned("whsec_a", "{}", h, 300, now + 301), false, "too old");
  assertEquals(await webhookSigned("whsec_a", "{}", null, 300, now), false);
  assertEquals(await webhookSigned("whsec_a", "{}", `${h},v1=00`, 300, now), true, "a second signature beside the right one");
});

Deno.test("Stripe's bracketed form encoding", () => {
  assertEquals(form({ a: 1, b: { c: "d", e: [{ f: 2 }] }, g: undefined }).toString(), "a=1&b%5Bc%5D=d&b%5Be%5D%5B0%5D%5Bf%5D=2");
});

Deno.test("a /v2 request posts JSON under its own version, and /v1 a form under the pinned one", async () => {
  const sent: { url: string; version: string | null; type: string | null; body: string | null }[] = [];
  const call = stripe({
    key: "sk_test", api: "https://stripe.test",
    // deno-lint-ignore require-await
    fetcher: async (url, init) => {
      const h = new Headers(init?.headers);
      sent.push({ url: String(url), version: h.get("stripe-version"), type: h.get("content-type"), body: init?.body ? String(init.body) : null });
      return new Response("{}");
    },
  });
  await call("POST", "/v2/core/accounts", { metadata: { tenant: A }, include: ["configuration.recipient"] });
  await call("GET", "/v2/core/accounts/acct_1", { include: ["configuration.recipient"] });
  await call("POST", "/v1/customers", { metadata: { tenant: A } });
  assertEquals(sent, [
    { url: "https://stripe.test/v2/core/accounts", version: STRIPE_V2_VERSION, type: "application/json", body: JSON.stringify({ metadata: { tenant: A }, include: ["configuration.recipient"] }) },
    { url: `https://stripe.test/v2/core/accounts/acct_1?${new URLSearchParams({ "include[0]": "configuration.recipient" })}`, version: STRIPE_V2_VERSION, type: null, body: null },
    { url: "https://stripe.test/v1/customers", version: STRIPE_VERSION, type: "application/x-www-form-urlencoded", body: String(form({ metadata: { tenant: A } })) },
  ]);
});

Deno.test("a trial ends on the same day the months on, or the last day of a shorter month", () => {
  const at = (iso: string, months: number) => chargesAt(new Date(iso), months).toISOString();
  assertEquals(at("2026-11-05T14:30:15.250Z", 3), "2027-02-05T14:30:15.250Z", "the time of day is kept");
  assertEquals(at("2026-11-30T09:00:00Z", 3), "2027-02-28T09:00:00.000Z", "Nov 30 has no Feb 30");
  assertEquals(at("2026-12-31T23:59:59Z", 2), "2027-02-28T23:59:59.000Z", "past a year's end, to a short month");
  assertEquals(at("2027-11-30T09:00:00Z", 3), "2028-02-29T09:00:00.000Z", "a leap year's Feb 29");
  assertEquals(at("2026-01-31T00:00:00Z", 1), "2026-02-28T00:00:00.000Z");
  assertEquals(at("2026-03-31T10:00:00Z", 12), "2027-03-31T10:00:00.000Z", "a year on");
  assertEquals(at("2026-08-31T10:00:00Z", 6), "2027-02-28T10:00:00.000Z");
  assertEquals(at("2026-12-15T10:00:00Z", 24), "2028-12-15T10:00:00.000Z");
});

Deno.test("a published trial is months of plans the tenant sells, with a reminder", () => {
  const O = "o".repeat(43);
  const plans = { plus: { name: "Plus", interval: "month", prices: { usd: 499 } }, pro: { name: "Pro", interval: "month", prices: { usd: 999 } } };
  const ok = parsePublished({ owner: O, plans, trial: { months: 3, plans: ["plus"] } });
  assertEquals(ok.ok && ok.published.trial, { months: 3, plans: ["plus"], remindDays: 7 }, "the reminder defaults to 7 days");
  const own = parsePublished({ owner: O, plans, trial: { months: 24, plans: ["plus", "pro"], remindDays: 2 } });
  assertEquals(own.ok && own.published.trial, { months: 24, plans: ["plus", "pro"], remindDays: 2 });
  assertEquals(parsePublished({ owner: O, plans }).ok && !("trial" in (parsePublished({ owner: O, plans }) as { published: object }).published), true, "none published, none offered");
  for (const [trial, why] of [
    [null, "trial: an object"],
    [{ months: 0, plans: ["plus"] }, "trial: months 1 to 24"],
    [{ months: 25, plans: ["plus"] }, "trial: months 1 to 24"],
    [{ months: 1.5, plans: ["plus"] }, "trial: months 1 to 24"],
    [{ months: 3, plans: [] }, "trial: plans the tenant sells"],
    [{ months: 3, plans: ["coach"] }, "trial: plans the tenant sells"],
    [{ months: 3, plans: ["toString"] }, "trial: plans the tenant sells"],
    [{ months: 3, plans: "plus" }, "trial: plans the tenant sells"],
    [{ months: 3, plans: ["plus"], remindDays: 0 }, "trial: remindDays at least 1"],
  ] as const) {
    const r = parsePublished({ owner: O, plans, trial });
    assertEquals(r.ok ? "" : r.error, why, JSON.stringify(trial));
  }
});

const PUB = parsePublished({
  owner: "o".repeat(43), plans: { plus: { name: "Plus", interval: "month", prices: { usd: 499, brl: 1990 } }, pro: { name: "Pro", interval: "month", prices: { usd: 999 } } },
  trial: { months: 3, plans: ["plus"] },
});
const published = PUB.ok ? PUB.published : (() => { throw new Error("fixture"); })();

Deno.test("a consent is good only for the plan's price and the date months on, within a day", () => {
  const now = new Date("2026-11-05T12:00:00Z");
  const good = { plan: "plus", amount: 1990, currency: "brl", charges_at: "2027-02-05T12:00:00Z", terms: "t" };
  const check = (c: Partial<typeof good>) => { const r = consentChecked({ ...good, ...c }, published, now); return r.ok ? "ok" : `${r.kind} ${r.error}`; };
  assertEquals(check({}), "ok");
  assertEquals(check({ charges_at: "2027-02-06T11:59:59Z" }), "ok", "a day after");
  assertEquals(check({ charges_at: "2027-02-04T12:00:01Z" }), "ok", "a day before");
  assertEquals(check({ charges_at: "2027-02-06T12:00:01Z" }), "stale stale");
  assertEquals(check({ charges_at: "2027-01-05T12:00:00Z" }), "stale stale", "a shorter trial than promised");
  assertEquals(check({ amount: 499 }), "stale stale", "the usd price under brl");
  assertEquals(check({ currency: "usd", amount: 499 }), "ok");
  assertEquals(check({ plan: "pro", currency: "usd", amount: 999 }), "bad plan is one of plus");
  assertEquals(check({ plan: null as unknown as string }), "bad plan is one of plus");
  assertEquals(check({ currency: "eur" }), "bad currency is one of usd, brl");
  assertEquals(check({ charges_at: "someday" }), "bad amount and charges_at required");
  assertEquals(check({ amount: 19.9 }), "bad amount and charges_at required");
  assertEquals(consentChecked(good, { ...published, trial: undefined }, now).ok, false, "no trial published");
  const ok = consentChecked(good, published, now);
  assertEquals(ok.ok && ok.endsAt, Date.parse("2027-02-05T12:00:00Z") / 1000, "Stripe gets the date consented to, verbatim");
});

const sub = (over: Partial<Subscription> & { metadata?: Record<string, string> } = {}): Subscription => ({
  id: "sub_1", status: "trialing", current_period_end: 1_800_000_000, trial_end: 1_800_000_000, current_period_start: 1_000, created: 1_000, ...over,
  metadata: { tenant: A, account: "ana", plan: "plus", trial: "1", trial_amount: "1990", trial_currency: "brl", ...over.metadata },
});

Deno.test("an account's trial is where its newest trial subscription says", () => {
  const state = (s: Subscription) => trialOf([s], A, "ana", "plus")?.state;
  assertEquals(state(sub()), "running");
  assertEquals(state(sub({ cancel_at_period_end: true })), "cancelled");
  assertEquals(state(sub({ status: "active" })), "converted");
  assertEquals(state(sub({ status: "past_due" })), "converted");
  assertEquals(state(sub({ status: "canceled", metadata: { trial_failed: "1" } })), "failed");
  assertEquals(state(sub({ status: "canceled" })), "ended");
  assertEquals(state(sub({ status: "unpaid" })), "ended");
  assertEquals(state(sub({ status: "incomplete" })), undefined, "a trial never begun is none");
  assertEquals(state(sub({ status: "incomplete_expired" })), undefined);
  assertEquals(trialOf([sub()], A, "ana", "plus"), { state: "running", amount: 1990, currency: "brl", charges_at: 1_800_000_000 });
  // Not another plan's, another account's, another tenant's, or one that never was a trial.
  assertEquals(trialOf([sub()], A, "ana", "pro"), undefined);
  assertEquals(trialOf([sub()], A, "bea", "plus"), undefined);
  assertEquals(trialOf([sub()], B, "ana", "plus"), undefined);
  assertEquals(trialOf([sub({ metadata: { trial: "" } })], A, "ana", "plus"), undefined);
  assertEquals(trialOf([], A, "ana", "plus"), undefined);
  // The newest wins, whatever order Stripe lists them in.
  const old = sub({ id: "sub_old", status: "canceled", created: 10 }), young = sub({ id: "sub_new", created: 20 });
  assertEquals([trialOf([old, young], A, "ana", "plus")?.state, trialOf([young, old], A, "ana", "plus")?.state], ["running", "running"]);
});

Deno.test("a trial is spent by any subscription of the account but one never paid for", () => {
  const spent = (s: Subscription, account = "ana") => trialSpent([s], A, account);
  for (const status of ["trialing", "active", "past_due", "unpaid", "canceled", "paused"]) assertEquals(spent(sub({ status })), true, status);
  for (const status of ["incomplete", "incomplete_expired"]) assertEquals(spent(sub({ status })), false, status);
  assertEquals(spent(sub({ metadata: { plan: "pro", trial: "" } })), true, "another plan, paid and not a trial");
  assertEquals(spent(sub(), "bea"), false, "another account");
  assertEquals(trialSpent([sub()], B, "ana"), false, "another tenant");
});

Deno.test("only the first charge of a trial is a failed trial", () => {
  assertEquals(firstChargeFailed(sub({ status: "past_due", current_period_start: 1_800_000_000 })), true);
  assertEquals(firstChargeFailed(sub({ status: "unpaid", current_period_start: 1_800_000_000 })), true);
  assertEquals(firstChargeFailed(sub({ status: "past_due", current_period_start: 1_802_592_000 })), false, "a later renewal's");
  assertEquals(firstChargeFailed(sub({ status: "trialing", current_period_start: 1_800_000_000 })), false);
  assertEquals(firstChargeFailed(sub({ status: "active", current_period_start: 1_800_000_000 })), false);
  assertEquals(firstChargeFailed(sub({ status: "past_due", current_period_start: 1_800_000_000, metadata: { trial: "" } })), false, "not a trial");
  assertEquals(firstChargeFailed(sub({ status: "past_due", trial_end: null, current_period_start: 1_800_000_000 })), false);
});

Deno.test("an entitlement carries a trial only for an account that has had one", () => {
  const base = { issuer: "https://b.example", tenant: A, account: "ana", plan: "plus", active: true, through: 5, manage: "m", ver: 1, now: 100 };
  assertEquals("trial" in entitlementClaims(base), false);
  assertEquals(entitlementClaims({ ...base, trial: { state: "running", amount: 1990, currency: "brl", charges_at: 9 } }).trial, { state: "running", amount: 1990, currency: "brl", charges_at: 9 });
});

Deno.test("Checkout is opened as it always was, and a trial adds only its own", () => {
  const p = { customer: "cus_1", account: "ana", locale: "pt-BR", price: "price_1", back: `${A}/back`, metadata: { tenant: A, account: "ana", plan: "plus" }, destination: "acct_1", feePercent: 10 };
  assertEquals(checkoutSession(p), {
    mode: "subscription", customer: "cus_1", client_reference_id: "ana", locale: "pt-BR", line_items: [{ price: "price_1", quantity: 1 }],
    success_url: `${A}/back`, cancel_url: `${A}/back`, metadata: p.metadata,
    subscription_data: { metadata: p.metadata, transfer_data: { destination: "acct_1" }, application_fee_percent: 10 },
  });
  const trial = { ...p, currency: "brl", trialEnd: 1_800_000_000, metadata: { ...p.metadata, trial: "1" } };
  assertEquals(checkoutSession(trial), {
    mode: "subscription", customer: "cus_1", client_reference_id: "ana", locale: "pt-BR", line_items: [{ price: "price_1", quantity: 1 }], currency: "brl",
    payment_method_collection: "always", success_url: `${A}/back`, cancel_url: `${A}/back`, metadata: trial.metadata,
    subscription_data: {
      metadata: trial.metadata, transfer_data: { destination: "acct_1" }, application_fee_percent: 10,
      trial_end: 1_800_000_000, trial_settings: { end_behavior: { missing_payment_method: "cancel" } },
    },
  });
});

Deno.test("a DELETE to Stripe carries no body and a GET's query", async () => {
  const seen: { method?: string; url: string; body: unknown }[] = [];
  const s = stripe({ key: "k", api: "https://stripe.test", fetcher: ((url: string, init: RequestInit) => {
    seen.push({ method: init.method, url, body: init.body });
    return Promise.resolve(Response.json({ id: "sub_1", status: "canceled" }));
  }) as unknown as typeof fetch });
  await s("DELETE", "/v1/subscriptions/sub_1");
  assertEquals(seen, [{ method: "DELETE", url: "https://stripe.test/v1/subscriptions/sub_1" }]);
});
