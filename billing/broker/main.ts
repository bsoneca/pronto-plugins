// The billing broker: one service the operator runs for every application,
// in front of the one Stripe platform account the operator holds. An
// application sells subscriptions through it with no Stripe account, key or
// dashboard of its own; its author is paid out through a Stripe connected
// account the broker opens for the application's origin (core.ts says how
// tenants stay apart).
//
// It keeps nothing of its own: which origin a connected account pays, which
// tenant and account a customer and a subscription are, all ride Stripe's
// metadata, and a tenant's plans are read from its origin. A webhook is
// answered only once the tenant has taken the entitlement it carries, so
// Stripe's own retries redeliver what a tenant missed.
//
// Plain HTTP: TLS is the platform's. BROKER_SECRET derives the manage
// tokens; BILLING_SIGNING_KEY is the key entitlements are signed with, kept
// because a tenant checks a token it receives against the key it was told
// of. One instance: an entitlement's `ver` is this process's clock.
import { base64url, esc, type Jwk, json, page, randomToken, signEs256 } from "../shared.ts";
import {
  accountOf, chargesAt, checkoutSession, type Consent, consentChecked, Limiter, readCapped, derivedKey, entitlementClaims, entitlementOf,
  firstChargeFailed, lookupKeyOf, manageTokenOf, ownerOf, parsePublished, type Plan, type Published, returnTo, same, type Subscription,
  tenantOf, trialOf, trialSpent,
} from "./core.ts";
import { type Routed, type Stripe, StripeError, webhookSigned } from "./stripe.ts";

/** Where a tenant publishes its owner and its plans. */
export const PUBLISHED_PATH = "/.well-known/pronto-billing.json";
/** Where a tenant takes the entitlements the broker pushes. */
export const EVENTS_PATH = "/billing/events";
/** Where a tenant gives back what an account consented to, for a ticket it minted. */
export const CONSENT_PATH = "/billing/trial/consent";

export const SUBSCRIPTION_EVENTS = new Set([
  "customer.subscription.created", "customer.subscription.updated", "customer.subscription.deleted",
  "customer.subscription.paused", "customer.subscription.resumed",
]);

/** A connected account as /v2/core/accounts has it, its recipient configuration included. */
interface Account {
  id: string;
  metadata?: Record<string, string>;
  configuration?: { recipient?: { capabilities?: { stripe_balance?: { stripe_transfers?: { status?: string } } } } };
}
const RECIPIENT = { include: ["configuration.recipient"] };
/** Whether an account takes the transfers a tenant's payments make to it: its payouts are set up. */
export const payable = (a: Account | null): a is Account => a?.configuration?.recipient?.capabilities?.stripe_balance?.stripe_transfers?.status === "active";
/** How an author sets up payouts again, from their own terminal. */
const ONBOARD = "deno run billing/owner.ts onboard";

/** The signing key from its JWK, or one minted for this run when there is none. */
export async function signingKey(jwk?: string): Promise<{ key: CryptoKey; publicJwk: Jwk }> {
  if (!jwk) {
    const pair = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]);
    const kid = randomToken(8);
    return { key: pair.privateKey, publicJwk: { ...(await crypto.subtle.exportKey("jwk", pair.publicKey)), kid, alg: "ES256", use: "sig" } };
  }
  const priv = JSON.parse(jwk) as Jwk;
  if (priv.kty !== "EC" || priv.crv !== "P-256" || !priv.d || !priv.kid) throw new Error("BILLING_SIGNING_KEY is a P-256 private JWK with a kid");
  const key = await crypto.subtle.importKey("jwk", priv, { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
  return { key, publicJwk: { kty: "EC", crv: "P-256", x: priv.x, y: priv.y, kid: priv.kid, alg: "ES256", use: "sig" } };
}

/** A new signing key, as BILLING_SIGNING_KEY holds it. */
export async function newSigningKey(): Promise<string> {
  const pair = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]);
  return JSON.stringify({ ...(await crypto.subtle.exportKey("jwk", pair.privateKey)), kid: base64url(crypto.getRandomValues(new Uint8Array(6))) });
}

async function body(req: Request): Promise<Record<string, unknown>> {
  const text = await readCapped(req.body, 4096, req.headers.get("content-length"));
  if (text === null) return {};
  if ((req.headers.get("content-type") ?? "").startsWith("application/json")) {
    try {
      const v = JSON.parse(text);
      return typeof v === "object" && v !== null ? v : {};
    } catch {
      return {};
    }
  }
  return Object.fromEntries(new URLSearchParams(text));
}

export async function broker(p: {
  issuer: string;
  secret: string;
  stripe: Stripe;
  webhookSecret: string;
  signingKey?: string;
  /** The share of each payment the platform keeps, in percent. */
  feePercent?: number;
  /** How the broker reaches tenants: their published plans, and their events. */
  fetcher?: typeof fetch;
  cacheMs?: number;
}) {
  const issuer = p.issuer.replace(/\/$/, "");
  // A broker on a developer's machine serves tenants there too.
  const local = /^https?:\/\/localhost(:\d+)?$/.test(issuer);
  const tenant = (v: unknown) => tenantOf(v, local);
  const manageKey = await derivedKey(p.secret, "billing manage");
  const signing = await signingKey(p.signingKey);
  const fetcher = p.fetcher ?? fetch;
  const cacheMs = p.cacheMs ?? 300_000;
  const fee = p.feePercent ?? 0;
  if (!(fee >= 0 && fee < 100)) throw new Error("the fee is a percentage under 100");
  // What a caller nobody signed in may make the broker ask of Stripe.
  const perTenant = new Limiter(120), perClient = new Limiter(20);
  // A trial route's own: a tenant's calls all leave from one address, so this is generous, and it is
  // taken before a ticket is tried, which a junk one must not spend the tenant's bucket on.
  const trialClient = new Limiter(60);
  // Each entitlement newer than every one before it, though two are signed in one millisecond.
  let lastVer = 0;
  const nextVer = () => (lastVer = Math.max(lastVer + 1, Date.now()));

  // A tenant's published plans, for a few minutes.
  const published = new Map<string, { at: number; doc: Published }>();
  async function publishedBy(t: string, fresh = false): Promise<{ ok: true; doc: Published } | { ok: false; error: string }> {
    const held = published.get(t);
    if (!fresh && held && Date.now() - held.at < cacheMs) return { ok: true, doc: held.doc };
    let res: Response;
    try {
      res = await fetcher(`${t}${PUBLISHED_PATH}`, { redirect: "manual", signal: AbortSignal.timeout(10_000) });
    } catch {
      return { ok: false, error: `${t}${PUBLISHED_PATH} unreachable` };
    }
    if (res.status !== 200) {
      await res.body?.cancel();
      return { ok: false, error: `${t}${PUBLISHED_PATH} answered ${res.status}` };
    }
    const text = await readCapped(res.body, 16_384, res.headers.get("content-length"));
    if (text === null) return { ok: false, error: `${t}${PUBLISHED_PATH} is over 16 KB` };
    let parsed;
    try {
      parsed = parsePublished(JSON.parse(text));
    } catch {
      return { ok: false, error: `${t}${PUBLISHED_PATH} is not JSON` };
    }
    if (!parsed.ok) return { ok: false, error: `${t}${PUBLISHED_PATH}: ${parsed.error}` };
    published.set(t, { at: Date.now(), doc: parsed.published });
    return { ok: true, doc: parsed.published };
  }

  // The connected account that pays a tenant's author, found by its metadata;
  // a tenant without one is not looked for again for a minute.
  const accounts = new Map<string, string>();
  const none = new Map<string, number>();
  async function connectedAccount(t: string): Promise<Account | null> {
    const id = accounts.get(t);
    if (id) return await p.stripe<Account>("GET", `/v2/core/accounts/${id}`, RECIPIENT);
    if ((none.get(t) ?? 0) > Date.now()) return null;
    if (none.size > 10_000) none.clear();
    // Twenty at most to a page, as /v2 lists are; a listed account leaves its
    // configurations out, so the one found is read again.
    let page: string | null = null;
    for (;;) {
      const got: { data: Account[]; next_page_url?: string | null } = await p.stripe("GET", "/v2/core/accounts", {
        limit: 20, applied_configurations: ["recipient"], ...(page ? { page } : {}),
      });
      const found = got.data.find((a) => a.metadata?.tenant === t);
      if (found) {
        accounts.set(t, found.id);
        return await p.stripe<Account>("GET", `/v2/core/accounts/${found.id}`, RECIPIENT);
      }
      page = got.next_page_url ? new URL(got.next_page_url, "https://api.stripe.com").searchParams.get("page") : null;
      if (!page || got.data.length === 0) {
        none.set(t, Date.now() + 60_000);
        return null;
      }
    }
  }

  // Every customer one account of one tenant is: Stripe's search lags a
  // creation by up to a minute, so the one just made is named beside it.
  async function customersOf(t: string, account: string, known?: string): Promise<string[]> {
    const found = await p.stripe<{ data: { id: string }[] }>("GET", "/v1/customers/search", {
      query: `metadata['tenant']:'${t}' AND metadata['account']:'${account}'`, limit: 10,
    });
    return [...new Set([...(known ? [known] : []), ...found.data.map((c) => c.id)])];
  }

  async function subscriptionsOf(customers: string[]): Promise<Subscription[]> {
    const all: Subscription[] = [];
    for (const customer of customers) {
      all.push(...(await p.stripe<{ data: Subscription[] }>("GET", "/v1/subscriptions", { customer, status: "all", limit: 100 })).data);
    }
    return all;
  }

  async function priceOf(t: string, planId: string, plan: Plan): Promise<string> {
    const key = await lookupKeyOf(t, planId, plan);
    const found = await p.stripe<{ data: { id: string }[] }>("GET", "/v1/prices", { lookup_keys: [key], active: true, limit: 1 });
    if (found.data[0]) return found.data[0].id;
    const [[currency, amount], ...others] = Object.entries(plan.prices);
    const price = await p.stripe<{ id: string }>("POST", "/v1/prices", {
      currency, unit_amount: amount, recurring: { interval: plan.interval }, lookup_key: key, transfer_lookup_key: true,
      ...(others.length ? { currency_options: Object.fromEntries(others.map(([c, a]) => [c, { unit_amount: a }])) } : {}),
      product_data: { name: `${plan.name} · ${new URL(t).host}`, metadata: { tenant: t, plan: planId } },
      metadata: { tenant: t, plan: planId },
    });
    return price.id;
  }

  // The entitlement of one account to one plan, read from Stripe and signed for its tenant.
  async function entitlement(t: string, account: string, plan: string, known?: string) {
    const ver = nextVer();
    const subs = await subscriptionsOf(await customersOf(t, account, known));
    const held = entitlementOf(subs, t, account, plan);
    const token = await signEs256(signing.key, signing.publicJwk.kid!, entitlementClaims({
      issuer, tenant: t, account, plan, ...held, manage: await manageTokenOf(manageKey, t, account), ver, trial: trialOf(subs, t, account, plan),
    }));
    return { held, token };
  }

  /** Pushes an entitlement to its tenant: whether it was taken, and whether
   * it never will be (a refusal of the tenant's own, not an outage). */
  async function push(t: string, token: string): Promise<{ taken: boolean; refused: boolean; why: string }> {
    try {
      const res = await fetcher(`${t}${EVENTS_PATH}`, {
        method: "POST", headers: { "content-type": "application/jwt" }, body: token, redirect: "manual", signal: AbortSignal.timeout(10_000),
      });
      await res.body?.cancel();
      return { taken: res.ok, refused: res.status >= 400 && res.status < 500 && res.status !== 408 && res.status !== 429, why: `answered ${res.status}` };
    } catch {
      return { taken: false, refused: false, why: "unreachable" };
    }
  }

  // An author sets up payouts with the secret whose hash the origin
  // publishes: from their own terminal (billing/owner.ts onboard),
  // so the secret is never in a link. An account already set up is managed at
  // Stripe, never through the broker.
  async function onboard(req: Request): Promise<Response> {
    const b = await body(req);
    const t = tenant(b.tenant);
    if (!t || typeof b.owner !== "string" || b.owner.length < 32) return json(400, { error: "tenant and owner required" });
    const doc = await publishedBy(t, true);
    if (!doc.ok) return json(409, { error: doc.error });
    if (!same(doc.doc.owner, await ownerOf(b.owner))) return json(403, { error: "owner refused" });
    let acct = await connectedAccount(t);
    if (payable(acct)) return json(409, { error: "payouts are set up: manage them at https://connect.stripe.com/express_login" });
    if (!acct) {
      // Stripe asks a recipient for a contact email, which the author gives as they set up
      // payouts: the origin publishes none.
      const email = typeof b.email === "string" && /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(b.email) && b.email.length <= 254 ? b.email : null;
      if (!email) return json(400, { error: "email required: where Stripe reaches the author about payouts" });
      const platform = await p.stripe<{ country: string }>("GET", "/v1/account");
      const country = typeof b.country === "string" && /^[A-Z]{2}$/.test(b.country) ? b.country : platform.country;
      // A recipient of the transfers its tenant's payments make: the platform pays
      // Stripe's fees and answers for what the account owes. In the platform's own
      // country Stripe opens no recipient that could not also take card payments;
      // across a border it is a recipient alone.
      const home = country === platform.country;
      acct = await p.stripe<Account>("POST", "/v2/core/accounts", {
        dashboard: "express", contact_email: email, identity: { country: country.toLowerCase() }, metadata: { tenant: t },
        defaults: { profile: { business_url: t }, responsibilities: { fees_collector: "application", losses_collector: "application" } },
        configuration: {
          recipient: { capabilities: { stripe_balance: { stripe_transfers: { requested: true } } } },
          ...(home ? { merchant: { capabilities: { card_payments: { requested: true } } } } : {}),
        },
        ...RECIPIENT,
      }, `account ${t} ${country}`);
      accounts.set(t, acct.id);
      none.delete(t);
    }
    const done = `${issuer}/onboarded?tenant=${encodeURIComponent(t)}`;
    // Onboarding asks for what each configuration the account has needs: Stripe reads
    // them from the account, and takes no list of them on the link.
    const link = await p.stripe<{ url: string }>("POST", "/v2/core/account_links", {
      account: acct.id,
      use_case: { type: "account_onboarding", account_onboarding: { refresh_url: `${done}&expired=1`, return_url: done } },
    });
    return json(200, { url: link.url });
  }

  async function onboarded(url: URL): Promise<Response> {
    const t = tenant(url.searchParams.get("tenant"));
    if (!t) return page("Payouts", `<h1>This can't continue</h1>`, 400);
    const host = esc(new URL(t).host);
    if (url.searchParams.get("expired")) return page("Payouts", `<h1>That link expired</h1><p>Run <code>${ONBOARD}</code> for <span class="origin">${host}</span> again.</p>`);
    const acct = await connectedAccount(t);
    return payable(acct)
      ? page("Payouts set up", `<h1>Payouts for <span class="origin">${host}</span> are set up</h1><p>Manage them at <a href="https://connect.stripe.com/express_login">Stripe</a>.</p>`)
      : page("Payouts", `<h1>Payouts for <span class="origin">${host}</span> aren't set up yet</h1><p>Run <code>${ONBOARD}</code> again to finish.</p>`);
  }

  // The customer an account is at Stripe, made if it has none, with every subscription of it.
  async function customerOf(t: string, account: string): Promise<{ customer: string; subs: Subscription[] }> {
    const found = await customersOf(t, account);
    // Made at most once a day by this key, and found by search after.
    const customer = found[0] ?? (await p.stripe<{ id: string }>("POST", "/v1/customers", { metadata: { tenant: t, account } }, `customer ${t} ${account}`)).id;
    return { customer, subs: await subscriptionsOf([...new Set([customer, ...found])]) };
  }

  // One at a time for an account of a tenant, so two requests do not both find no customer, no
  // subscription and no open session, and each open a Checkout of its own.
  const queues = new Map<string, Promise<unknown>>();
  async function locked<T>(key: string, fn: () => Promise<T>): Promise<T> {
    const run = (queues.get(key) ?? Promise.resolve()).then(fn);
    const tail = run.catch(() => {});
    queues.set(key, tail);
    try {
      return await run;
    } finally {
      if (queues.get(key) === tail) queues.delete(key);
    }
  }

  // Opens Checkout for an account, closing any other it left open first, so two tabs pay once.
  // `refuse` looks at the account's subscriptions and may turn it away.
  function openSession(s: {
    t: string; account: string; acct: Account; planId: string; plan: Plan; back: string; metadata: Record<string, string>; locale: unknown;
    currency?: string; trialEnd?: number; refuse: (subs: Subscription[]) => Response | null;
  }): Promise<Response> {
    return locked(`${s.t} ${s.account}`, async () => {
      const { customer, subs } = await customerOf(s.t, s.account);
      const no = s.refuse(subs);
      if (no) return no;
      for (const o of (await p.stripe<{ data: { id: string }[] }>("GET", "/v1/checkout/sessions", { customer, status: "open", limit: 100 })).data) {
        await p.stripe("POST", `/v1/checkout/sessions/${o.id}/expire`);
      }
      const session = await p.stripe<{ url: string }>("POST", "/v1/checkout/sessions", checkoutSession({
        customer, account: s.account, locale: s.locale, price: await priceOf(s.t, s.planId, s.plan), back: s.back, metadata: s.metadata,
        destination: s.acct.id, feePercent: fee, currency: s.currency, trialEnd: s.trialEnd,
      }));
      return json(200, { url: session.url });
    });
  }

  // A tenant's page sends an account to pay for a plan. Anyone may ask: what
  // it opens is a payment for that account, which only adds to it.
  // A read of Stripe for one account, and nothing written anywhere: the account's customers and
  // subscriptions, answered only by whether Stripe answered. A flag's live check reads Stripe through
  // it as the tester (PRONTO-218: stripe_door's), where every other path writes (a ticket, a session).
  async function probe(req: Request, client: string): Promise<Response> {
    const b = await body(req);
    const t = tenant(b.tenant);
    const account = accountOf(b.account);
    if (!t || !account) return json(400, { error: "tenant and account required" });
    if (!perClient.take(client) || !perTenant.take(t)) return json(429, { error: "too many probes; try again in a minute" });
    // Which way this read goes, as its tenant asked for its reader just now; `direct` is true only when
    // the read went straight to Stripe, so a flip's check sees whether the door answered.
    const route = await (p.stripe as Routed).route?.();
    await subscriptionsOf(await customersOf(t, account));
    return json(200, { ok: true, direct: route === "direct" });
  }

  async function checkout(req: Request, client: string): Promise<Response> {
    const b = await body(req);
    const t = tenant(b.tenant);
    const account = accountOf(b.account);
    if (!t || !account) return json(400, { error: "tenant and account required" });
    if (!perClient.take(client) || !perTenant.take(t)) return json(429, { error: "too many checkouts; try again in a minute" });
    const back = returnTo(t, b.return);
    if (!back) return json(400, { error: "return is a path on the tenant's origin" });
    const doc = await publishedBy(t);
    if (!doc.ok) {
      console.error(`billing: ${doc.error}`);
      return json(409, { error: "the tenant's billing document is unavailable" });
    }
    const planId = String(b.plan ?? "");
    const plan = Object.hasOwn(doc.doc.plans, planId) ? doc.doc.plans[planId] : undefined;
    if (!plan) return json(400, { error: `plan is one of ${Object.keys(doc.doc.plans).join(", ")}` });
    const acct = await connectedAccount(t);
    if (!payable(acct)) return json(409, { error: "the tenant's payouts are not set up" });
    const currency = typeof b.currency === "string" && Object.hasOwn(plan.prices, b.currency) ? b.currency : undefined;
    return await openSession({
      t, account, acct, planId, plan, back, metadata: { tenant: t, account, plan: planId }, locale: b.locale, currency,
      refuse: (subs) => entitlementOf(subs, t, account, planId).active ? json(409, { error: "already subscribed" }) : null,
    });
  }

  // What an account consented to, given back by its tenant for the ticket the tenant minted: the
  // tenant's own word that the account asked, signed in, with the flag on. A ticket is good once.
  async function consentOf(t: string, account: string, ticket: unknown): Promise<Consent | Response> {
    if (typeof ticket !== "string" || ticket.length < 16 || ticket.length > 200) return json(400, { error: "ticket required" });
    let res: Response;
    try {
      res = await fetcher(`${t}${CONSENT_PATH}`, {
        method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ account, ticket }), redirect: "manual", signal: AbortSignal.timeout(10_000),
      });
    } catch {
      console.error(`billing: ${t}${CONSENT_PATH} unreachable`);
      return json(502, { error: "the tenant is unavailable" });
    }
    if (res.status !== 200) {
      await res.body?.cancel();
      if (res.status === 404) return json(403, { error: "ticket refused" });
      console.error(`billing: ${t}${CONSENT_PATH} answered ${res.status}`);
      return json(502, { error: "the tenant is unavailable" });
    }
    const text = await readCapped(res.body, 4096, res.headers.get("content-length"));
    let c: Record<string, unknown> | null = null;
    try {
      c = text === null ? null : JSON.parse(text);
    } catch { /* not JSON: refused below */ }
    if (typeof c !== "object" || c === null) return json(502, { error: "the tenant's consent is unreadable" });
    const str = (v: unknown) => (typeof v === "string" ? v : null);
    return { plan: str(c.plan), amount: Number.isInteger(c.amount) ? c.amount as number : null, currency: str(c.currency), charges_at: str(c.charges_at), terms: str(c.terms) };
  }

  // What the broker needs of a trial request: the tenant's document with a trial in it, and a
  // ticket the tenant stands behind. A broker that knows no /trial/* answers 404 to all of it, so
  // an old broker never charges for what a new page promised free.
  async function trialAsk(b: Record<string, unknown>, client: string) {
    const t = tenant(b.tenant);
    const account = accountOf(b.account);
    if (!t || !account) return { err: json(400, { error: "tenant and account required" }) };
    if (!trialClient.take(client)) return { err: json(429, { error: "too many requests; try again in a minute" }) };
    const doc = await publishedBy(t);
    if (!doc.ok) {
      console.error(`billing: ${doc.error}`);
      return { err: json(409, { error: "the tenant's billing document is unavailable" }) };
    }
    if (!doc.doc.trial) return { err: json(404, { error: "no trial" }) };
    const consent = await consentOf(t, account, b.ticket);
    if (consent instanceof Response) return { err: consent };
    if (!perTenant.take(t)) return { err: json(429, { error: "too many requests; try again in a minute" }) };
    return { t, account, doc: doc.doc, trial: doc.doc.trial, consent };
  }

  // The plans an account may take as a trial, priced and dated: none once it has held a plan.
  async function trialOffer(req: Request, client: string): Promise<Response> {
    const b = await body(req);
    const r = await trialAsk(b, client);
    if (r.err) return r.err;
    const { t, account, doc, trial } = r;
    const acct = await connectedAccount(t);
    if (!payable(acct)) return json(409, { error: "the tenant's payouts are not set up" });
    if (trialSpent(await subscriptionsOf(await customersOf(t, account)), t, account)) return json(200, { eligible: false, why: "used", offers: [] });
    const charges = chargesAt(new Date(), trial.months).toISOString();
    return json(200, {
      eligible: true,
      offers: trial.plans.map((id) => {
        const plan = doc.plans[id];
        const currency = typeof b.currency === "string" && Object.hasOwn(plan.prices, b.currency) ? b.currency : Object.keys(plan.prices)[0];
        return { plan: id, name: plan.name, amount: plan.prices[currency as keyof Plan["prices"]], currency, interval: plan.interval, months: trial.months, charges_at: charges };
      }),
    });
  }

  // A trial: the one the account consented to, which the ticket gave back, is what Stripe gets.
  async function trialCheckout(req: Request, client: string): Promise<Response> {
    const b = await body(req);
    const r = await trialAsk(b, client);
    if (r.err) return r.err;
    const { t, account, doc, consent } = r;
    const back = returnTo(t, b.return);
    if (!back) return json(400, { error: "return is a path on the tenant's origin" });
    const checked = consentChecked(consent, doc);
    if (!checked.ok) return json(checked.kind === "stale" ? 409 : 400, { error: checked.error });
    const acct = await connectedAccount(t);
    if (!payable(acct)) return json(409, { error: "the tenant's payouts are not set up" });
    const metadata = { tenant: t, account, plan: checked.plan, trial: "1", trial_amount: String(checked.amount), trial_currency: checked.currency };
    return await openSession({
      t, account, acct, planId: checked.plan, plan: checked.def, back, metadata, locale: b.locale, currency: checked.currency, trialEnd: checked.endsAt,
      refuse: (subs) => trialSpent(subs, t, account) ? json(409, { error: "used" }) : null,
    });
  }

  // What only an account's tenant holds the token for: its portal at Stripe,
  // and its entitlement read again, for a tenant that missed a push.
  async function managed(b: Record<string, unknown>): Promise<{ t: string; account: string } | Response> {
    const t = tenant(b.tenant);
    const account = accountOf(b.account);
    if (!t || !account || typeof b.manage !== "string") return json(400, { error: "tenant, account and manage required" });
    if (!same(b.manage, await manageTokenOf(manageKey, t, account))) return json(403, { error: "manage token refused" });
    return { t, account };
  }

  let portalConfiguration: string | undefined;
  async function portal(req: Request): Promise<Response> {
    const b = await body(req);
    const m = await managed(b);
    if (m instanceof Response) return m;
    const back = returnTo(m.t, b.return);
    if (!back) return json(400, { error: "return is a path on the tenant's origin" });
    const [customer] = await customersOf(m.t, m.account);
    if (!customer) return json(404, { error: "no subscription" });
    portalConfiguration ??= (await p.stripe<{ id: string }>("POST", "/v1/billing_portal/configurations", {
      business_profile: { headline: "Your subscription" },
      features: {
        subscription_cancel: { enabled: true, mode: "at_period_end" },
        payment_method_update: { enabled: true },
        invoice_history: { enabled: true },
      },
    })).id;
    const session = await p.stripe<{ url: string }>("POST", "/v1/billing_portal/sessions", { customer, return_url: back, configuration: portalConfiguration });
    return json(200, { url: session.url });
  }

  async function resync(req: Request): Promise<Response> {
    const b = await body(req);
    const m = await managed(b);
    if (m instanceof Response) return m;
    if (typeof b.plan !== "string" || !/^[a-z][a-z0-9-]{0,31}$/.test(b.plan)) return json(400, { error: "plan required" });
    return json(200, { token: (await entitlement(m.t, m.account, b.plan)).token });
  }

  // What Stripe says changed, read again from Stripe and pushed to the tenant
  // as the account's entitlement; answered once the tenant has taken it, and
  // pushed again if Stripe changed while it was on its way. A tenant that
  // refuses it is told no more of it: its own fault is not every tenant's.
  // A trial whose first charge failed ends at once: no dunning, and no charge a retry setting
  // of the operator's dashboard would make later. Read again from Stripe, so an event that
  // lags a subscription already ended asks nothing; one instance, so the ids in hand are all.
  const ending = new Set<string>();
  async function endFailedTrial(event: Subscription): Promise<void> {
    if (event.metadata?.trial !== "1" || (event.status !== "past_due" && event.status !== "unpaid") || ending.has(event.id)) return;
    ending.add(event.id);
    try {
      const fresh = await p.stripe<Subscription>("GET", `/v1/subscriptions/${event.id}`);
      if (!firstChargeFailed(fresh)) return;
      // The failed first invoice must not stay payable: one that was paid since means the charge
      // recovered and the trial stands; an open one is voided. A key without Invoices access is
      // logged and the cancel goes on, since Stripe stops collecting an invoice when its
      // subscription is cancelled.
      if (typeof fresh.latest_invoice === "string") {
        try {
          const inv = await p.stripe<{ status: string }>("GET", `/v1/invoices/${fresh.latest_invoice}`);
          if (inv.status === "paid") return;
          if (inv.status === "open") await p.stripe("POST", `/v1/invoices/${fresh.latest_invoice}/void`);
        } catch (e) {
          if (!(e instanceof StripeError && e.status === 403)) throw e;
          console.error(`billing: the Stripe key cannot read or void invoices (403); cancelling ${event.id} without voiding`);
        }
      }
      await p.stripe("POST", `/v1/subscriptions/${event.id}`, { metadata: { trial_failed: "1" } }, `trial failed ${event.id}`);
      await p.stripe("DELETE", `/v1/subscriptions/${event.id}`);
    } finally {
      ending.delete(event.id);
    }
  }

  // Two Checkouts that raced past the lock (another broker instance, or a customer Stripe's search
  // had not found) can each start a trial: the newer, still trialing and uncharged, is cancelled
  // at once and marked, so it never shows as the account's trial. The older keeps its trial.
  async function endDuplicateTrial(event: Subscription & { customer: string }, t: string, account: string): Promise<void> {
    if (event.metadata.trial !== "1" || ending.has(event.id)) return;
    ending.add(event.id);
    try {
      const subs = await subscriptionsOf(await customersOf(t, account, event.customer));
      const mine = subs.find((x) => x.id === event.id);
      if (mine?.status !== "trialing") return;
      const older = subs.some((x) => x.id !== event.id && x.metadata.tenant === t && x.metadata.account === account && x.metadata.trial === "1" &&
        x.metadata.trial_duplicate !== "1" && x.status !== "incomplete" && x.status !== "incomplete_expired" &&
        ((x.created ?? 0) < (mine.created ?? 0) || ((x.created ?? 0) === (mine.created ?? 0) && x.id < mine.id)));
      if (!older) return;
      await p.stripe("POST", `/v1/subscriptions/${event.id}`, { metadata: { trial_duplicate: "1" } }, `trial duplicate ${event.id}`);
      await p.stripe("DELETE", `/v1/subscriptions/${event.id}`);
    } finally {
      ending.delete(event.id);
    }
  }

  async function webhook(req: Request): Promise<Response> {
    const payload = await readCapped(req.body, 262_144, req.headers.get("content-length"));
    if (payload === null) return json(413, { error: "too large" });
    if (!(await webhookSigned(p.webhookSecret, payload, req.headers.get("stripe-signature")))) return json(400, { error: "signature" });
    const event = JSON.parse(payload) as { id: string; type: string; data: { object: Subscription & { customer: string } } };
    if (!SUBSCRIPTION_EVENTS.has(event.type)) return json(200, { ignored: event.type });
    const sub = event.data.object;
    const t = tenantOf(sub.metadata?.tenant, true);
    const account = accountOf(sub.metadata?.account);
    const plan = sub.metadata?.plan;
    if (!t || !account || !plan) return json(200, { ignored: "not a pronto subscription" });
    await endFailedTrial(sub);
    if (event.type === "customer.subscription.created") await endDuplicateTrial(sub, t, account);
    let sent: { active: boolean; through: number } | null = null;
    for (let round = 0; round < 3; round++) {
      const { held, token } = await entitlement(t, account, plan, sub.customer);
      if (sent && sent.active === held.active && sent.through === held.through) break;
      const r = await push(t, token);
      if (r.refused) {
        console.error(`billing: ${t}${EVENTS_PATH} ${r.why} for ${event.id}; not sent again`);
        return json(200, { refused: event.id });
      }
      if (!r.taken) {
        console.error(`billing: ${t}${EVENTS_PATH} ${r.why} for ${event.id}`);
        return json(502, { error: `tenant ${r.why}` });
      }
      sent = held;
    }
    return json(200, { delivered: event.id });
  }

  return async function handler(req: Request, info?: Deno.ServeHandlerInfo): Promise<Response> {
    const url = new URL(req.url);
    const path = url.pathname;
    try {
      if (req.method === "GET" && path === "/jwks") return json(200, { keys: [signing.publicJwk] });
      if (req.method === "POST" && path === "/onboard") return await onboard(req);
      if (req.method === "GET" && path === "/onboarded") return await onboarded(url);
      if (req.method === "POST" && path === "/checkout") {
        // The platform's front appends the caller it saw last; a direct connection is its address.
        const addr = info?.remoteAddr as Deno.NetAddr | undefined;
        return await checkout(req, req.headers.get("x-forwarded-for")?.split(",").at(-1)?.trim() || addr?.hostname || "");
      }
      if (req.method === "POST" && (path === "/trial/offer" || path === "/trial/checkout")) {
        const addr = info?.remoteAddr as Deno.NetAddr | undefined;
        const client = req.headers.get("x-forwarded-for")?.split(",").at(-1)?.trim() || addr?.hostname || "";
        return await (path === "/trial/offer" ? trialOffer(req, client) : trialCheckout(req, client));
      }
      if (req.method === "POST" && path === "/portal") return await portal(req);
      if (req.method === "POST" && path === "/probe") {
        const addr = info?.remoteAddr as Deno.NetAddr | undefined;
        return await probe(req, req.headers.get("x-forwarded-for")?.split(",").at(-1)?.trim() || addr?.hostname || "");
      }
      if (req.method === "POST" && path === "/resync") return await resync(req);
      if (req.method === "POST" && path === "/stripe") return await webhook(req);
      if (req.method === "GET" && path === "/health") return json(200, { ok: true });
      return json(404, { error: "not found" });
    } catch (e) {
      if (e instanceof StripeError) {
        console.error(`billing: stripe ${e.status} ${e.code}: ${e.message}`);
        return json(502, { error: "stripe refused" });
      }
      console.error(e);
      return json(500, { error: "internal error" });
    }
  };
}

/** One broker answering in two of Stripe's modes: a tenant `sandboxed` names (an app's previews,
 * say) sells through the sandbox's key, every other through the live one. Each mode is a broker
 * of its own over one issuer and signing key, so a tenant checks either's entitlements alike; a
 * request goes to the mode its tenant is in, and Stripe's webhook to the mode whose secret signed
 * it. What names no tenant (/jwks, /health) is the live broker's. */
export function twoModes(p: {
  live: (req: Request, info?: Deno.ServeHandlerInfo) => Promise<Response>;
  sandbox: (req: Request, info?: Deno.ServeHandlerInfo) => Promise<Response>;
  sandboxed: (tenant: string) => boolean;
  sandboxWebhookSecret: string;
}) {
  return async function handler(req: Request, info?: Deno.ServeHandlerInfo): Promise<Response> {
    const url = new URL(req.url), path = url.pathname;
    let tenant: unknown = null;
    if (req.method === "GET" && path === "/onboarded") tenant = url.searchParams.get("tenant");
    else if (req.method === "POST" && ["/checkout", "/trial/offer", "/trial/checkout", "/portal", "/resync", "/onboard", "/probe"].includes(path)) {
      try {
        tenant = (await req.clone().json())?.tenant;
      } catch {
        tenant = null;
      }
    } else if (req.method === "POST" && path === "/stripe") {
      const payload = await req.clone().text();
      const sandboxSigned = await webhookSigned(p.sandboxWebhookSecret, payload, req.headers.get("stripe-signature"));
      return (sandboxSigned ? p.sandbox : p.live)(req, info);
    }
    return (typeof tenant === "string" && p.sandboxed(tenant.replace(/\/$/, "")) ? p.sandbox : p.live)(req, info);
  };
}

if (import.meta.main) {
  const env = (k: string) => Deno.env.get(k);
  if (Deno.args[0] === "keygen") {
    console.log(await newSigningKey());
    Deno.exit(0);
  }
  const issuer = env("BROKER_ISSUER");
  const secret = env("BROKER_SECRET");
  if (!issuer || !secret) throw new Error("BROKER_ISSUER and BROKER_SECRET are required");
  const port = Number(env("PORT") ?? 28463);
  const { stripe, switched, askedDoor, forAccount } = await import("./stripe.ts");
  // Once per platform account: the one endpoint Stripe sends every app's
  // subscriptions to, whose secret STRIPE_WEBHOOK_SECRET then holds.
  if (Deno.args[0] === "webhook") {
    const key = env("STRIPE_SECRET_KEY");
    if (!key) throw new Error("STRIPE_SECRET_KEY is required");
    const made = await stripe({ key })<{ secret: string }>("POST", "/v1/webhook_endpoints", {
      url: `${issuer.replace(/\/$/, "")}/stripe`, enabled_events: [...SUBSCRIPTION_EVENTS], description: "pronto-billing broker",
    });
    console.log(`STRIPE_WEBHOOK_SECRET=${made.secret}`);
    Deno.exit(0);
  }
  const settings = { issuer, secret, signingKey: env("BILLING_SIGNING_KEY"), feePercent: Number(env("BILLING_FEE_PERCENT") ?? 0) };
  const key = env("STRIPE_SECRET_KEY");
  // Off by default: set (by metal.nu --airlock), every Stripe call goes through the airlock's door at
  // this address, which holds the keys, and the broker holds none (PRONTO-135).
  const door = env("STRIPE_DOOR")?.replace(/\/$/, "");
  // While it moves (PRONTO-218): the door beside the broker's own key, each call through the door when
  // its request asked for it (`door`, the tenant's flag for its reader); the key leaves the broker once
  // the flag is on for everyone.
  const doorAsked = env("STRIPE_DOOR_ASKED") === "1";
  if (doorAsked && !(door && key)) throw new Error("STRIPE_DOOR_ASKED moves the broker between its key and the door: it needs STRIPE_DOOR and STRIPE_SECRET_KEY");
  if (door && key && !doorAsked) throw new Error("STRIPE_DOOR and STRIPE_SECRET_KEY: through the door, the airlock holds the key and the broker none");
  // Only a broker that is asked which way reads its callers' bodies for it; any other serves as before.
  const asked = <A extends unknown[]>(h: (req: Request, ...rest: A) => Promise<Response>) => doorAsked ? forAccount(h) : h;
  const client = (k: string | undefined, d: string) =>
    doorAsked ? switched({ direct: stripe({ key: k! }), door: stripe({ door: d }), on: askedDoor }) : door ? stripe({ door: d }) : stripe({ key: k! });
  if (key || door) {
    const webhookSecret = env("STRIPE_WEBHOOK_SECRET");
    if (!webhookSecret) throw new Error("STRIPE_WEBHOOK_SECRET is required with STRIPE_SECRET_KEY: bin/pronto-billing-broker webhook");
    const live = await broker({ ...settings, stripe: client(key, `${door}/door/stripe`), webhookSecret });
    // A sandbox beside the live account, for the tenants BILLING_SANDBOX_TENANTS matches: an
    // app's previews test a purchase there, with Stripe's test cards, never a live charge.
    // Through the door, the sandbox's key is the airlock's too, behind its door stripe-sandbox.
    const sandboxKey = env("STRIPE_SANDBOX_SECRET_KEY"), sandboxTenants = env("BILLING_SANDBOX_TENANTS");
    if (doorAsked && sandboxTenants && !sandboxKey) throw new Error("STRIPE_DOOR_ASKED with a sandbox needs STRIPE_SANDBOX_SECRET_KEY too: the sandbox's calls go straight to Stripe while the flag is off");
    if (door && sandboxKey && !doorAsked) throw new Error("STRIPE_DOOR and STRIPE_SANDBOX_SECRET_KEY: the airlock holds the sandbox's key too");
    if (sandboxKey || (door && sandboxTenants)) {
      const sandboxWebhookSecret = env("STRIPE_SANDBOX_WEBHOOK_SECRET");
      if (!sandboxWebhookSecret || !sandboxTenants) throw new Error("a sandbox (STRIPE_SANDBOX_SECRET_KEY, or BILLING_SANDBOX_TENANTS through the door) needs STRIPE_SANDBOX_WEBHOOK_SECRET and BILLING_SANDBOX_TENANTS");
      const pattern = new RegExp(sandboxTenants);
      const sandbox = await broker({ ...settings, stripe: client(sandboxKey, `${door}/door/stripe-sandbox`), webhookSecret: sandboxWebhookSecret });
      console.warn(`billing: tenants matching ${sandboxTenants} sell through the sandbox`);
      Deno.serve({ port }, asked(twoModes({ live, sandbox, sandboxed: (t) => pattern.test(t), sandboxWebhookSecret })));
    } else {
      Deno.serve({ port }, asked(live));
    }
  } else {
    // No Stripe key: a stand-in, on a broker only a developer's machine reaches.
    if (!/^https?:\/\/localhost(:\d+)?$/.test(issuer.replace(/\/$/, ""))) throw new Error("STRIPE_SECRET_KEY is required off localhost");
    if (settings.signingKey) throw new Error("the stand-in signs with a key of its own: unset BILLING_SIGNING_KEY");
    const { fakeStripe } = await import("./fake.ts");
    const fake = fakeStripe(issuer);
    for (const t of (env("BILLING_FAKE_TENANTS") ?? "").split(/[\s,]+/)) if (t) fake.ready(t);
    const handler = await broker({ ...settings, stripe: fake.stripe, webhookSecret: fake.webhookSecret });
    fake.connect(handler);
    console.warn("billing: no STRIPE_SECRET_KEY, so the stand-in at /fake/stripe takes payments");
    Deno.serve({ hostname: "127.0.0.1", port }, (req, info) => fake.handle(req) ?? handler(req, info));
  }
}
