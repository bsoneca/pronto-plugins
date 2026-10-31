// A stand-in for Stripe on a developer's machine, where the operator's
// Stripe key is not: the broker serves its pages under /fake/stripe and calls
// it in place of Stripe's API. It keeps what it is told in memory and speaks
// just enough of Stripe for the broker: connected accounts and their
// onboarding, customers, prices, a checkout that pays at a press, and a
// portal that cancels or fails the next payment. Each change reaches the
// broker as Stripe's webhook would, signed, and is sent again until the
// broker takes it. main refuses it on any issuer but localhost.
import { esc, json, randomToken } from "../shared.ts";
import { type Stripe, StripeError, signWebhook } from "./stripe.ts";

// Stripe's objects, as loosely as the stand-in keeps them.
// deno-lint-ignore no-explicit-any
type Obj = Record<string, any>;
const DAY = 86_400;

// A press is answered by a redirect to the app, which form-action governs too.
const PAGE_CSP = "default-src 'none'; style-src 'unsafe-inline'; form-action 'self' https: http://localhost:*; frame-ancestors 'none'; base-uri 'none'";
function page(title: string, body: string, status = 200): Response {
  return new Response(`<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>${esc(title)}</title>
<style>body{margin:0;min-height:100vh;display:grid;place-items:center;font:17px/1.5 system-ui,sans-serif;background:#f6f9fc;color:#1a1f36}
main{max-width:28rem;padding:2rem 1.5rem}h1{font-size:1.4rem}.test{display:inline-block;padding:2px 8px;border-radius:6px;background:#ffde92;color:#5a3e00;font-size:13px;font-weight:700}
button{min-height:48px;padding:0 20px;border:0;border-radius:10px;background:#635bff;color:#fff;font:inherit;font-weight:700;cursor:pointer;margin:4px 0}
button.quiet{background:#e3e8ee;color:#1a1f36}a{color:#635bff}@media (prefers-color-scheme:dark){body{background:#0a2540;color:#f6f9fc}button.quiet{background:#2b3f5c;color:#f6f9fc}a{color:#a39dff}}</style></head>
<body><main><p><span class="test">Test mode · no money moves</span></p>${body}</main></body></html>
`, { status, headers: { "content-type": "text/html; charset=utf-8", "content-security-policy": PAGE_CSP, "cache-control": "no-store" } });
}
const go = (to: string) => new Response(null, { status: 303, headers: { location: to, "cache-control": "no-store" } });

export function fakeStripe(issuer: string, { now = () => Math.floor(Date.now() / 1000), searchLagMs = 0 } = {}) {
  const base = `${issuer.replace(/\/$/, "")}/fake/stripe`;
  const webhookSecret = `whsec_fake_${randomToken(12)}`;
  const accounts = new Map<string, Obj>(), customers = new Map<string, Obj>(), prices = new Map<string, Obj>();
  const subscriptions = new Map<string, Obj>(), sessions = new Map<string, Obj>(), portals = new Map<string, Obj>(), links = new Map<string, Obj>();
  const idempotent = new Map<string, Obj>();
  const id = (prefix: string) => `${prefix}_${randomToken(10).replace(/[-_]/g, "x")}`;
  let broker: ((req: Request) => Promise<Response>) | undefined;
  const undelivered: string[] = [];
  let retrying: ReturnType<typeof setInterval> | undefined;

  async function deliver(payload: string): Promise<boolean> {
    if (!broker) return false;
    const res = await broker(new Request(`${issuer}/stripe`, {
      method: "POST", body: payload, headers: { "content-type": "application/json", "stripe-signature": await signWebhook(webhookSecret, payload) },
    }));
    await res.body?.cancel();
    return res.ok;
  }
  // Sent again every few seconds until the broker takes it, as Stripe does over days.
  async function emit(type: string, sub: Obj): Promise<boolean> {
    const payload = JSON.stringify({ id: id("evt"), type, created: now(), data: { object: structuredClone(sub) } });
    if (await deliver(payload)) return true;
    undelivered.push(payload);
    retrying ??= setInterval(async () => {
      for (const p of undelivered.splice(0)) if (!(await deliver(p))) undelivered.push(p);
      if (undelivered.length === 0) { clearInterval(retrying); retrying = undefined; }
    }, 3000);
    Deno.unrefTimer(retrying);
    return false;
  }

  const list = (m: Map<string, Obj>, keep: (o: Obj) => boolean) => ({ data: [...m.values()].filter(keep), has_more: false });
  // A connected account as /v2/core/accounts has it, whose transfers turn active once
  // onboarded; one in the platform's own country (the stand-in's is the US) takes card payments too.
  const account = (tenant: string, country: string, transfers: string) => ({
    id: id("acct"), dashboard: "express", identity: { country }, metadata: { tenant },
    applied_configurations: country === "us" ? ["merchant", "recipient"] : ["recipient"],
    configuration: { recipient: { capabilities: { stripe_balance: { stripe_transfers: { status: transfers } } } } },
  });
  const missing = (what: string) => { throw new StripeError(404, "resource_missing", `No such ${what}`); };

  // Async as Stripe's client is, though the stand-in answers at once.
  // deno-lint-ignore require-await
  const stripe: Stripe = async <T,>(method: string, path: string, params: Obj = {}, key?: string): Promise<T> => {
    // /v2/core/accounts is spoken as /v2/accounts, beside /v1's kinds.
    const [, , kind, oid, sub] = (path.startsWith("/v2/core/") ? `/v2${path.slice("/v2/core".length)}` : path).split("/");
    // As Stripe: a key used again with other parameters is refused.
    const sent = JSON.stringify(params);
    const earlier = key ? idempotent.get(`${path} ${key}`) : undefined;
    if (earlier && earlier.sent !== sent) throw new StripeError(400, "idempotency_error", "Keys for idempotent requests can only be used with the same parameters");
    if (earlier) return earlier.made as T;
    const remember = (o: Obj) => { if (key) idempotent.set(`${path} ${key}`, { sent, made: o }); return o as T; };
    if (kind === "account" && method === "GET") return { id: "acct_platform", country: "US" } as T;
    // As Stripe's: twenty to a page at most, and a listed account leaves its configurations out.
    if (kind === "accounts" && method === "GET" && !oid && params.limit > 20) throw new StripeError(400, "invalid_fields", "limit: Limit cannot be greater than 20");
    if (kind === "accounts" && method === "GET" && !oid) return { data: [...accounts.values()].map(({ configuration: _, ...a }) => a), next_page_url: null } as T;
    if (kind === "accounts" && method === "GET") return (accounts.get(oid) ?? missing("account")) as T;
    if (kind === "accounts" && method === "POST") {
      if (params.configuration?.recipient && !params.contact_email) throw new StripeError(400, "invalid_fields", "configuration.recipient: If configuration.recipient is supplied, the Account must have a contact email.");
      // As Stripe's: in the platform's country, transfers come only with card payments, and across a border without them.
      if ((params.identity?.country === "us") !== !!params.configuration?.merchant?.capabilities?.card_payments?.requested) {
        throw new StripeError(400, "capability_not_available_without_other_capability", "The stripe_balance.stripe_transfers capability cannot be requested without the configuration.merchant.capabilities.card_payments capability.");
      }
      const a = account(params.metadata?.tenant, params.identity?.country, "restricted");
      accounts.set(a.id, a);
      return remember(a);
    }
    if (kind === "account_links") {
      // As Stripe's: the link reads the account's configurations, and takes no list of them.
      const unknown = Object.keys(params.use_case?.account_onboarding ?? {}).find((k) => !["refresh_url", "return_url", "collection_options"].includes(k));
      if (unknown) throw new StripeError(400, "invalid_fields", `use_case.account_onboarding.${unknown}: Unknown field.`);
      const l = { id: id("link"), account: params.account, return_url: params.use_case?.account_onboarding?.return_url };
      links.set(l.id, l);
      return { url: `${base}/onboard/${l.id}` } as T;
    }
    if (kind === "customers" && oid === "search") {
      // As Stripe's: a customer is found only once its index has caught up.
      const m = /^metadata\['tenant'\]:'([^']*)' AND metadata\['account'\]:'([^']*)'$/.exec(params.query);
      return list(customers, (c) => !!m && c.metadata.tenant === m[1] && c.metadata.account === m[2] && c.indexed <= Date.now()) as T;
    }
    if (kind === "customers" && method === "POST") {
      const c = { id: id("cus"), metadata: params.metadata ?? {}, indexed: Date.now() + searchLagMs };
      customers.set(c.id, c);
      return remember(c);
    }
    if (kind === "subscriptions") return list(subscriptions, (s) => s.customer === params.customer) as T;
    if (kind === "prices" && method === "GET") return list(prices, (p) => p.active && (params.lookup_keys ?? []).includes(p.lookup_key)) as T;
    if (kind === "prices" && method === "POST") {
      const p = { id: id("price"), active: true, ...params, product: { id: id("prod"), ...params.product_data } };
      prices.set(p.id, p);
      return remember(p);
    }
    if (kind === "checkout" && oid === "sessions" && method === "GET") {
      return list(sessions, (s) => s.customer === params.customer && params.status === "open") as T;
    }
    if (kind === "checkout" && oid === "sessions" && sub) {
      sessions.delete(sub);
      return { id: sub, status: "expired" } as T;
    }
    if (kind === "checkout" && oid === "sessions") {
      const s = { id: id("cs"), ...params };
      sessions.set(s.id, s);
      return { id: s.id, url: `${base}/pay/${s.id}` } as T;
    }
    if (kind === "billing_portal" && oid === "configurations") return remember({ id: id("bpc") });
    if (kind === "billing_portal" && oid === "sessions") {
      const s = { id: id("bps"), ...params };
      portals.set(s.id, s);
      return { url: `${base}/portal/${s.id}` } as T;
    }
    throw new StripeError(400, "fake_unsupported", `the stand-in doesn't speak ${method} ${path}`);
  };

  async function handle(req: Request): Promise<Response> {
    const url = new URL(req.url);
    const [kind, oid] = url.pathname.slice("/fake/stripe/".length).split("/");
    const action = req.method === "POST" ? new URLSearchParams(await req.text()).get("do") : null;
    if (kind === "onboard") {
      const l = links.get(oid);
      if (!l) return page("Expired", `<h1>This link expired</h1>`, 404);
      if (action === "done") {
        accounts.get(l.account)!.configuration.recipient.capabilities.stripe_balance.stripe_transfers.status = "active";
        links.delete(oid);
        return go(l.return_url);
      }
      return page("Set up payouts", `<h1>Set up payouts</h1><p>The test account is filled in for you.</p>
<form method="post"><button name="do" value="done">Agree and submit</button></form>`);
    }
    if (kind === "pay") {
      const s = sessions.get(oid);
      if (!s) return page("Expired", `<h1>This checkout expired</h1>`, 404);
      const price = prices.get(s.line_items[0].price)!;
      const currency = s.currency ?? price.currency;
      const amount = currency === price.currency ? price.unit_amount : price.currency_options[currency].unit_amount;
      if (action === "pay") {
        sessions.delete(oid);
        const sub = {
          id: id("sub"), object: "subscription", customer: s.customer, status: "active",
          current_period_end: now() + 30 * DAY, metadata: s.subscription_data.metadata,
          transfer_data: s.subscription_data.transfer_data, items: { data: [{ price }] },
        };
        subscriptions.set(sub.id, sub);
        await emit("customer.subscription.created", sub);
        return go(s.success_url);
      }
      if (action === "cancel") { sessions.delete(oid); return go(s.cancel_url); }
      return page("Checkout", `<h1>${esc(price.product.name)}</h1>
<p><strong>${(amount / 100).toFixed(2)} ${esc(currency.toUpperCase())}</strong> a ${esc(price.recurring.interval)}</p>
<form method="post"><button name="do" value="pay">Subscribe</button> <button class="quiet" name="do" value="cancel">Back</button></form>`);
    }
    if (kind === "portal") {
      const s = portals.get(oid);
      if (!s) return page("Expired", `<h1>This session expired</h1>`, 404);
      const mine = [...subscriptions.values()].filter((x) => x.customer === s.customer);
      const target = mine.find((x) => x.id === new URL(req.url).searchParams.get("sub"));
      if (target && action === "cancel") {
        target.status = "canceled";
        await emit("customer.subscription.deleted", target);
      } else if (target && action === "fail") {
        target.status = "past_due";
        await emit("customer.subscription.updated", target);
      } else if (target && action === "renew") {
        Object.assign(target, { status: "active", current_period_end: target.current_period_end + 30 * DAY });
        await emit("customer.subscription.updated", target);
      }
      if (action) return go(url.pathname);
      const rows = mine.map((x) => `<section><p><strong>${esc(x.items.data[0].price.product.name)}</strong> · ${esc(x.status)}, until ${new Date(x.current_period_end * 1000).toISOString().slice(0, 10)}</p>
<form method="post" action="${esc(`${url.pathname}?sub=${x.id}`)}">${x.status === "canceled" ? "" : `<button class="quiet" name="do" value="cancel">Cancel now</button> <button class="quiet" name="do" value="fail">Fail the next payment</button> `}<button class="quiet" name="do" value="renew">Renew</button></form></section>`).join("");
      return page("Your subscription", `<h1>Your subscription</h1>${rows || "<p>None.</p>"}<p><a href="${esc(s.return_url)}">Back</a></p>`);
    }
    return json(404, { error: "not found" });
  }

  return {
    stripe,
    webhookSecret,
    /** The broker the stand-in's webhooks reach. */
    connect(handler: (req: Request) => Promise<Response>) { broker = handler; },
    /** A response for the stand-in's own pages, or null for the broker's. */
    handle: (req: Request): Promise<Response> | null => new URL(req.url).pathname.startsWith("/fake/stripe/") ? handle(req) : null,
    /** A tenant whose payouts are set up already, as a local launch wants its own. */
    ready(tenant: string) {
      const a = account(tenant, "us", "active");
      accounts.set(a.id, a);
    },
    /** For tests: what the stand-in holds. */
    held: { accounts, customers, prices, subscriptions },
    emit,
    /** Stops sending again what the broker has not taken. */
    close() { clearInterval(retrying); retrying = undefined; },
  };
}
