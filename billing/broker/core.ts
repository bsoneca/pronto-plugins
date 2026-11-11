// What the billing broker decides, apart from its network: which tenant a
// request is for, what that tenant sells, which of its accounts holds a plan
// and until when, and the tokens that carry those answers back. One operator
// runs the broker and holds the one Stripe platform account; every
// application is its own tenant, paid out to a Stripe connected account of
// its own author's.
//
// A tenant is an application's origin, as it is to the identity broker, and
// the app holds no secret. What it sells is read from the origin itself, at
// /.well-known/pronto-billing.json, beside the hash of a secret its author
// alone holds: whoever serves the origin chooses the hash, and only whoever
// holds the secret may set up the payouts it names, so neither a stranger
// racing the author through Stripe's onboarding nor a copy of another
// origin's document attaches a bank account to it. Tenants are never merged:
// a customer is one account of one tenant, and every token the broker signs
// has that tenant alone as its audience.
import { base64url, originOf, sha256url } from "../shared.ts";
import { RULES } from "../rules.ts";
export { readCapped } from "../shared.ts";

const enc = new TextEncoder();

/** The keys the broker derives from its one secret, each for one purpose. */
export async function derivedKey(secret: string, label: string): Promise<CryptoKey> {
  if (secret.length < 32) throw new Error("the broker secret is at least 32 characters");
  const root = await crypto.subtle.importKey("raw", enc.encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const derived = new Uint8Array(await crypto.subtle.sign("HMAC", root, enc.encode(label)));
  return crypto.subtle.importKey("raw", derived, { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
}

async function mac(key: CryptoKey, ...parts: string[]): Promise<string> {
  return base64url(new Uint8Array(await crypto.subtle.sign("HMAC", key, enc.encode(parts.join("\u0000")))));
}

/**
 * The tenant an origin names, or null. Not a host the broker could be turned
 * against: no IP literal, no localhost or private name, unless the broker
 * itself runs on a developer's machine (`local`).
 */
export function tenantOf(v: unknown, local = false): string | null {
  const t = originOf(v);
  if (!t) return null;
  const host = new URL(t).hostname;
  if (!/^[a-z0-9.-]+$/.test(host)) return null;
  if (local) return t;
  if (/^[0-9.]+$/.test(host) || !host.includes(".")) return null;
  if (/(^|\.)(localhost|local|internal|localdomain|home\.arpa|test|invalid|example)$/.test(host)) return null;
  return t;
}

/** What a tenant publishes of its author's secret. */
export const ownerOf = (secret: string) => sha256url(`pronto-billing owner\u0000${secret}`);

/** What an account presents to manage its subscriptions: delivered to its
 * tenant with every entitlement, and never to anyone else. */
export const manageTokenOf = (key: CryptoKey, tenant: string, account: string) => mac(key, "manage", tenant, account);

/** The locales Stripe's Checkout takes; any other is its language, or auto. */
const LOCALES = new Set(["bg", "cs", "da", "de", "el", "en", "en-GB", "es", "es-419", "et", "fi", "fil", "fr", "fr-CA", "hr", "hu", "id", "it", "ja", "ko", "lt", "lv", "ms", "mt", "nb", "nl", "pl", "pt", "pt-BR", "ro", "ru", "sk", "sl", "sv", "th", "tr", "vi", "zh", "zh-HK", "zh-TW"]);
export function checkoutLocale(v: unknown): string {
  if (typeof v !== "string") return "auto";
  if (LOCALES.has(v)) return v;
  const lang = v.split("-")[0];
  return LOCALES.has(lang) ? lang : "auto";
}

/** Two strings compared in time that does not depend on where they differ. */
export function same(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let d = 0;
  for (let i = 0; i < a.length; i++) d |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return d === 0;
}

/** An account of a tenant: the auth plane's subject, a uuid. */
export const accountOf = (v: unknown): string | null =>
  typeof v === "string" && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(v) ? v : null;

/** Where a tenant's page goes back to: a path on its own origin, never another's. */
export function returnTo(tenant: string, path: unknown): string | null {
  if (path === undefined || path === null || path === "") return `${tenant}/`;
  if (typeof path !== "string" || path.length > 512 || !path.startsWith("/") || path.startsWith("//") || /[\\\s]/.test(path)) return null;
  const url = new URL(path, tenant);
  return url.origin === tenant ? url.toString() : null;
}

/** The currencies a plan may be priced in, as Stripe names them (rules.cue). */
export const CURRENCIES = RULES.currencies;
export type Currency = typeof CURRENCIES[number];

/** A plan a tenant sells: a monthly or yearly subscription, priced in minor
 * units in each currency it names, the first its default. */
export interface Plan {
  name: string;
  interval: typeof RULES.plan.interval[number];
  prices: Partial<Record<Currency, number>>;
}

/** The free trial a tenant offers: how long, on which of its plans, and how
 * many days before the first charge it reminds the account. */
export interface Trial {
  months: number;
  plans: string[];
  remindDays: number;
}

/** What a tenant's /.well-known/pronto-billing.json says. */
export interface Published {
  /** ownerOf the author's secret. */
  owner: string;
  plans: Record<string, Plan>;
  trial?: Trial;
}

/** The tenant's published document, or why it is refused. */
export function parsePublished(doc: unknown): { ok: true; published: Published } | { ok: false; error: string } {
  if (typeof doc !== "object" || doc === null) return { ok: false, error: "not an object" };
  const d = doc as Record<string, unknown>;
  if (typeof d.owner !== "string" || !new RegExp(RULES.owner).test(d.owner)) return { ok: false, error: "no owner" };
  if (typeof d.plans !== "object" || d.plans === null) return { ok: false, error: "no plans" };
  const plans: Record<string, Plan> = {};
  for (const [id, raw] of Object.entries(d.plans as Record<string, unknown>)) {
    if (!new RegExp(RULES.plan.id).test(id)) return { ok: false, error: `plan ${id}: a lowercase name` };
    const p = raw as Record<string, unknown>;
    if (typeof p?.name !== "string" || p.name.trim() === "" || p.name.length > RULES.plan.nameMax) return { ok: false, error: `plan ${id}: a name` };
    if (!(RULES.plan.interval as readonly unknown[]).includes(p.interval)) return { ok: false, error: `plan ${id}: interval ${RULES.plan.interval.join(" or ")}` };
    const prices: Partial<Record<Currency, number>> = {};
    for (const [c, amount] of Object.entries((p.prices ?? {}) as Record<string, unknown>)) {
      if (!(CURRENCIES as readonly string[]).includes(c)) return { ok: false, error: `plan ${id}: currency ${c}` };
      if (!Number.isInteger(amount) || (amount as number) < RULES.price.min || (amount as number) > RULES.price.max) return { ok: false, error: `plan ${id}: ${c} in minor units, ${RULES.price.min} to ${RULES.price.max}` };
      prices[c as Currency] = amount as number;
    }
    if (Object.keys(prices).length === 0) return { ok: false, error: `plan ${id}: a price` };
    plans[id] = { name: p.name.trim(), interval: p.interval as Plan["interval"], prices };
  }
  if (Object.keys(plans).length === 0) return { ok: false, error: "no plans" };
  if (d.trial === undefined) return { ok: true, published: { owner: d.owner, plans } };
  const t = d.trial as Record<string, unknown> | null;
  if (typeof t !== "object" || t === null) return { ok: false, error: "trial: an object" };
  if (!Number.isInteger(t.months) || (t.months as number) < RULES.trial.monthsMin || (t.months as number) > RULES.trial.monthsMax) return { ok: false, error: `trial: months ${RULES.trial.monthsMin} to ${RULES.trial.monthsMax}` };
  if (!Array.isArray(t.plans) || t.plans.length === 0 || !t.plans.every((x) => typeof x === "string" && Object.hasOwn(plans, x))) {
    return { ok: false, error: "trial: plans the tenant sells" };
  }
  const remindDays = t.remindDays ?? RULES.trial.remindDays;
  if (!Number.isInteger(remindDays) || (remindDays as number) < 1) return { ok: false, error: "trial: remindDays at least 1" };
  return { ok: true, published: { owner: d.owner, plans, trial: { months: t.months as number, plans: t.plans as string[], remindDays: remindDays as number } } };
}

/** When a trial begun at `now` ends and charging starts: `months` calendar months on, the day
 * kept or, in a shorter month, the month's last, the time of day and UTC kept. */
export function chargesAt(now: Date, months: number): Date {
  const first = Date.UTC(now.getUTCFullYear(), now.getUTCMonth() + months, 1);
  const last = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth() + months + 1, 0)).getUTCDate();
  const out = new Date(first);
  out.setUTCDate(Math.min(now.getUTCDate(), last));
  out.setUTCHours(now.getUTCHours(), now.getUTCMinutes(), now.getUTCSeconds(), now.getUTCMilliseconds());
  return out;
}

/** What an account consented to, as its tenant keeps it. */
export interface Consent {
  plan: string | null;
  amount: number | null;
  currency: string | null;
  charges_at: string | null;
  terms: string | null;
}

/** Whether a consent is one the broker may start a trial from, now: what was shown is what Stripe
 * gets, so the amount must be the plan's price in that currency and the date the one `months` on,
 * within a day (a page left open overnight is stale, not wrong). `bad` is the caller's mistake,
 * `stale` a page to refresh. */
export function consentChecked(c: Consent, published: Published, now = new Date()):
  | { ok: true; plan: string; def: Plan; amount: number; currency: Currency; endsAt: number }
  | { ok: false; kind: "bad" | "stale"; error: string } {
  const trial = published.trial;
  if (!trial) return { ok: false, kind: "bad", error: "no trial" };
  if (typeof c.plan !== "string" || !trial.plans.includes(c.plan)) return { ok: false, kind: "bad", error: `plan is one of ${trial.plans.join(", ")}` };
  const plan = published.plans[c.plan];
  if (typeof c.currency !== "string" || !Object.hasOwn(plan.prices, c.currency)) return { ok: false, kind: "bad", error: `currency is one of ${Object.keys(plan.prices).join(", ")}` };
  const currency = c.currency as Currency;
  const at = typeof c.charges_at === "string" ? Date.parse(c.charges_at) : NaN;
  if (!Number.isInteger(c.amount) || Number.isNaN(at)) return { ok: false, kind: "bad", error: "amount and charges_at required" };
  if (c.amount !== plan.prices[currency]) return { ok: false, kind: "stale", error: "stale" };
  if (Math.abs(at - chargesAt(now, trial.months).getTime()) > 86_400_000) return { ok: false, kind: "stale", error: "stale" };
  return { ok: true, plan: c.plan, def: plan, amount: c.amount as number, currency, endsAt: Math.floor(at / 1000) };
}

/** The Stripe price a plan is sold at, named so that changing what the plan
 * costs names a new one: a subscription keeps the price it was sold at. */
export async function lookupKeyOf(tenant: string, plan: string, p: Plan): Promise<string> {
  const what = JSON.stringify([p.interval, Object.entries(p.prices).sort()]);
  const digest = base64url(new Uint8Array(await crypto.subtle.digest("SHA-256", enc.encode(JSON.stringify([tenant, what])))));
  return `pronto ${plan} ${digest}`;
}

/** The subset of a Stripe subscription the broker reads. */
export interface Subscription {
  id: string;
  status: string;
  current_period_end: number;
  metadata: Record<string, string>;
  /** Seconds. A trial's subscription has them; others may leave them out. */
  created?: number;
  cancel_at_period_end?: boolean;
  latest_invoice?: string | null;
  trial_end?: number | null;
  current_period_start?: number;
}

/** Whether an account holds a plan, and until when, from all of its
 * subscriptions: active while any one is active or trialing. A subscription
 * past due, unpaid, cancelled, paused or never paid holds nothing. */
export function entitlementOf(subs: readonly Subscription[], tenant: string, account: string, plan: string): { active: boolean; through: number } {
  let through = 0;
  for (const s of subs) {
    if (s.metadata.tenant !== tenant || s.metadata.account !== account || s.metadata.plan !== plan) continue;
    if (s.status === "active" || s.status === "trialing") through = Math.max(through, s.current_period_end);
  }
  return { active: through > 0, through };
}

/** Whether an account of a tenant has spent its trial: it holds, or held, a subscription to
 * any plan. Only one never paid for (incomplete) spends nothing. */
export function trialSpent(subs: readonly Subscription[], tenant: string, account: string): boolean {
  return subs.some((s) => s.metadata.tenant === tenant && s.metadata.account === account && s.status !== "incomplete" && s.status !== "incomplete_expired");
}

/** The state of an account's trial, from its newest subscription that began as one. */
export interface TrialClaim {
  state: typeof RULES.trialStates[number];
  amount: number;
  currency: string;
  /** When charging starts (started), in seconds: the trial's end. */
  charges_at: number;
}
export function trialOf(subs: readonly Subscription[], tenant: string, account: string, plan: string): TrialClaim | undefined {
  let newest: Subscription | undefined;
  for (const s of subs) {
    if (s.metadata.tenant !== tenant || s.metadata.account !== account || s.metadata.plan !== plan || s.metadata.trial !== "1") continue;
    if (s.status === "incomplete" || s.status === "incomplete_expired" || s.metadata.trial_duplicate === "1") continue;
    if (!newest || (s.created ?? 0) > (newest.created ?? 0)) newest = s;
  }
  if (!newest) return undefined;
  const state = newest.status === "trialing" ? (newest.cancel_at_period_end ? "cancelled" : "running")
    : newest.status === "active" || newest.status === "past_due" ? "converted"
    : newest.status === "canceled" && newest.metadata.trial_failed === "1" ? "failed"
    : "ended";
  return { state, amount: Number(newest.metadata.trial_amount), currency: newest.metadata.trial_currency, charges_at: newest.trial_end ?? 0 };
}

/** Whether a subscription's first charge failed: still in the period the trial's end opened, and
 * past due or unpaid. A later renewal's failure has a period of its own and is not this. */
export const firstChargeFailed = (s: Subscription): boolean =>
  (s.status === "past_due" || s.status === "unpaid") && s.metadata.trial === "1" && !!s.trial_end && s.current_period_start === s.trial_end;

/** The entitlement a tenant receives about one of its accounts: its audience
 * the tenant alone, and newer than every one before it by `ver`. */
export function entitlementClaims(p: {
  issuer: string; tenant: string; account: string; plan: string; active: boolean; through: number; manage: string; ver: number; now?: number;
  trial?: TrialClaim;
}): Record<string, unknown> {
  const now = p.now ?? Math.floor(Date.now() / 1000);
  return {
    iss: p.issuer, aud: p.tenant, sub: p.account, plan: p.plan,
    status: p.active ? "active" : "lapsed", through: p.through, manage: p.manage, ver: p.ver,
    ...(p.trial ? { trial: p.trial } : {}),
    iat: now, exp: now + 300,
  };
}

/** What Checkout is opened with. A trial adds the card, the trial's end and what to do if there
 * is no card by then; the metadata rides the session and the subscription alike. */
export function checkoutSession(p: {
  customer: string; account: string; locale: unknown; price: string; back: string; metadata: Record<string, string>;
  destination?: string; feePercent?: number; currency?: string; trialEnd?: number;
}): Record<string, unknown> {
  return {
    mode: "subscription", customer: p.customer, client_reference_id: p.account, locale: checkoutLocale(p.locale),
    line_items: [{ price: p.price, quantity: 1 }],
    ...(p.currency ? { currency: p.currency } : {}),
    ...(p.trialEnd ? { payment_method_collection: "always" } : {}),
    success_url: p.back, cancel_url: p.back, metadata: p.metadata,
    subscription_data: {
      metadata: p.metadata,
      ...(p.destination ? { transfer_data: { destination: p.destination } } : {}),
      ...(p.feePercent && p.feePercent > 0 ? { application_fee_percent: p.feePercent } : {}),
      ...(p.trialEnd ? { trial_end: p.trialEnd, trial_settings: { end_behavior: { missing_payment_method: "cancel" } } } : {}),
    },
  };
}

/** At most `per` requests a `windowMs` for each key, the oldest keys
 * forgotten past `keys`: what a caller nobody signed in may ask of Stripe. */
export class Limiter {
  #seen = new Map<string, { n: number; at: number }>();
  constructor(readonly per: number, readonly windowMs = 60_000, readonly keys = 10_000, readonly now = () => Date.now()) {}
  take(key: string): boolean {
    const t = this.now();
    let held = this.#seen.get(key);
    if (!held || t - held.at >= this.windowMs) held = { n: 0, at: t };
    this.#seen.delete(key);
    this.#seen.set(key, held);
    if (this.#seen.size > this.keys) this.#seen.delete(this.#seen.keys().next().value!);
    return ++held.n <= this.per;
  }
}
