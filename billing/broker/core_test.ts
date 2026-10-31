// The broker's decisions, apart from its network.
import { derivedKey, entitlementOf, lookupKeyOf, manageTokenOf, parsePublished, returnTo } from "./core.ts";
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
