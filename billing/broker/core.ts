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

/** The currencies a plan may be priced in, as Stripe names them. */
export const CURRENCIES = ["usd", "brl", "eur", "gbp"] as const;
export type Currency = typeof CURRENCIES[number];

/** A plan a tenant sells: a monthly or yearly subscription, priced in minor
 * units in each currency it names, the first its default. */
export interface Plan {
  name: string;
  interval: "month" | "year";
  prices: Partial<Record<Currency, number>>;
}

/** What a tenant's /.well-known/pronto-billing.json says. */
export interface Published {
  /** ownerOf the author's secret. */
  owner: string;
  plans: Record<string, Plan>;
}

/** The tenant's published document, or why it is refused. */
export function parsePublished(doc: unknown): { ok: true; published: Published } | { ok: false; error: string } {
  if (typeof doc !== "object" || doc === null) return { ok: false, error: "not an object" };
  const d = doc as Record<string, unknown>;
  if (typeof d.owner !== "string" || !/^[A-Za-z0-9_-]{43}$/.test(d.owner)) return { ok: false, error: "no owner" };
  if (typeof d.plans !== "object" || d.plans === null) return { ok: false, error: "no plans" };
  const plans: Record<string, Plan> = {};
  for (const [id, raw] of Object.entries(d.plans as Record<string, unknown>)) {
    if (!/^[a-z][a-z0-9-]{0,31}$/.test(id)) return { ok: false, error: `plan ${id}: a lowercase name` };
    const p = raw as Record<string, unknown>;
    if (typeof p?.name !== "string" || p.name.trim() === "" || p.name.length > 80) return { ok: false, error: `plan ${id}: a name` };
    if (p.interval !== "month" && p.interval !== "year") return { ok: false, error: `plan ${id}: interval month or year` };
    const prices: Partial<Record<Currency, number>> = {};
    for (const [c, amount] of Object.entries((p.prices ?? {}) as Record<string, unknown>)) {
      if (!(CURRENCIES as readonly string[]).includes(c)) return { ok: false, error: `plan ${id}: currency ${c}` };
      if (!Number.isInteger(amount) || (amount as number) < 50 || (amount as number) > 1_000_000) return { ok: false, error: `plan ${id}: ${c} in minor units, 50 to 1000000` };
      prices[c as Currency] = amount as number;
    }
    if (Object.keys(prices).length === 0) return { ok: false, error: `plan ${id}: a price` };
    plans[id] = { name: p.name.trim(), interval: p.interval, prices };
  }
  if (Object.keys(plans).length === 0) return { ok: false, error: "no plans" };
  return { ok: true, published: { owner: d.owner, plans } };
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

/** The entitlement a tenant receives about one of its accounts: its audience
 * the tenant alone, and newer than every one before it by `ver`. */
export function entitlementClaims(p: {
  issuer: string; tenant: string; account: string; plan: string; active: boolean; through: number; manage: string; ver: number; now?: number;
}): Record<string, unknown> {
  const now = p.now ?? Math.floor(Date.now() / 1000);
  return {
    iss: p.issuer, aud: p.tenant, sub: p.account, plan: p.plan,
    status: p.active ? "active" : "lapsed", through: p.through, manage: p.manage, ver: p.ver,
    iat: now, exp: now + 300,
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
