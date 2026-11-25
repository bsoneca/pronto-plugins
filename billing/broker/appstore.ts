// The App Store as a second source of entitlements beside Stripe (PRONTO-1435): an iOS app sells a plan through
// StoreKit, and the broker turns what Apple says into the same entitlement a tenant takes from a Stripe
// subscription (core.ts's entitlementClaims, pushed to EVENTS_PATH).
//
// Nothing a client says is believed. A signed transaction a player's device sends (or a notification Apple
// sends) is checked as Apple's: its ES256 signature, the certificate chain in its header up to a root the
// operator pinned, the two Apple extensions that make a certificate Apple's own for signing, the bundle id the
// operator tied to the tenant, and the environment. Even then it is only a pointer: the entitlement is read
// again from Apple's App Store Server API for the subscription (as a Stripe event is read again from Stripe), so
// a replayed, reordered or forged message can only make the broker ask Apple again. A refund or a revocation
// Apple reports ends the entitlement; a transaction bought for another account (appAccountToken is the account's
// uuid, which the iOS host sets at purchase) is refused.
//
// What it keeps: per tenant, account and plan, the time Apple said the subscription runs to, so that a Stripe
// event for the same account does not lapse what the App Store holds (main.ts merges the two), and which
// transactions and notifications were taken (store.ts).
//
// Inert until configured: APPSTORE_APPS (appstoreConfigFrom) is what turns on the routes and the merge; with it
// unset the broker answers 404 to /appstore and /appstore/transaction and behaves as before.
import { X509Certificate } from "node:crypto";
import { fromBase64url, originOf, readCapped, signEs256 } from "../shared.ts";
import { accountOf } from "./core.ts";
import type { Store } from "./store.ts";
import { RULES } from "../rules.ts";

/** A refusal with the status it is answered with: the caller's fault (4xx) or Apple's channel failing (502). */
export class AppStoreRefused extends Error {
  constructor(readonly status: number, message: string) {
    super(message);
  }
}

/** An iOS app the operator sells through the App Store for one tenant: its bundle id, the tenant (an origin) it
 * answers for, the plan each of its subscription products is, and whether its sandbox purchases count (a
 * rehearsal or TestFlight build; never a live broker's). */
export interface AppStoreApp {
  bundleId: string;
  tenant: string;
  products: Record<string, string>;
  sandbox: boolean;
}

export interface AppStoreConfig {
  apps: AppStoreApp[];
  /** The Apple root certificates that end a chain, PEM (Apple's public "Apple Root CA - G3"). */
  roots: string[];
  /** The App Store Server API key (App Store Connect > Users and Access > Integrations): issuer, key id, the .p8's PEM. */
  issuerId: string;
  keyId: string;
  key: string;
}

/** The configuration from the broker's environment, or undefined when APPSTORE_APPS is not set (the App Store is off).
 * Set, it must be whole and valid: a half-configured broker would take a transaction it cannot check, so it refuses to start. */
export function appstoreConfigFrom(env: (k: string) => string | undefined): AppStoreConfig | undefined {
  const raw = env("APPSTORE_APPS");
  if (!raw) return undefined;
  const need = ["APPSTORE_ROOTS", "APPSTORE_ISSUER_ID", "APPSTORE_KEY_ID", "APPSTORE_KEY"].filter((k) => !env(k));
  if (need.length) throw new Error(`APPSTORE_APPS is set: ${need.join(", ")} must be too`);
  let list: unknown;
  try {
    list = JSON.parse(raw);
  } catch {
    throw new Error("APPSTORE_APPS is a JSON list");
  }
  if (!Array.isArray(list) || list.length === 0) throw new Error("APPSTORE_APPS is a JSON list of at least one app");
  const apps = list.map((a): AppStoreApp => {
    const bundleId = typeof a?.bundleId === "string" && /^[A-Za-z0-9][A-Za-z0-9.-]{0,154}$/.test(a.bundleId) ? a.bundleId : null;
    const tenant = originOf(a?.tenant);
    if (!bundleId || !tenant) throw new Error("each of APPSTORE_APPS has a bundleId and a tenant (an https origin)");
    const products = a.products;
    if (typeof products !== "object" || products === null || Object.keys(products).length === 0) throw new Error(`APPSTORE_APPS ${bundleId}: products maps each product id to a plan`);
    for (const [product, plan] of Object.entries(products)) {
      if (!/^[A-Za-z0-9._-]{1,255}$/.test(product) || typeof plan !== "string" || !new RegExp(RULES.plan.id).test(plan)) throw new Error(`APPSTORE_APPS ${bundleId}: ${product} is not a product id mapped to a plan id`);
    }
    return { bundleId, tenant, products, sandbox: a.sandbox === true };
  });
  if (new Set(apps.map((a) => a.bundleId)).size !== apps.length) throw new Error("APPSTORE_APPS names a bundle id twice");
  const roots = env("APPSTORE_ROOTS")!.match(/-----BEGIN CERTIFICATE-----[\s\S]*?-----END CERTIFICATE-----/g) ?? [];
  if (roots.length === 0) throw new Error("APPSTORE_ROOTS is Apple's root certificates, PEM");
  for (const r of roots) new X509Certificate(r);
  return { apps, roots, issuerId: env("APPSTORE_ISSUER_ID")!, keyId: env("APPSTORE_KEY_ID")!, key: env("APPSTORE_KEY")! };
}

// The extensions Apple puts on the certificates that sign App Store data: on the leaf 1.2.840.113635.100.6.11.1 and
// on the intermediate 1.2.840.113635.100.6.2.1 (DER of the OID). Any certificate the same intermediate issued for
// another purpose (an app developer's own, say) lacks the first, and signs no transaction.
const LEAF_OID = Uint8Array.of(0x06, 0x0a, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x63, 0x64, 0x06, 0x0b, 0x01);
const INTERMEDIATE_OID = Uint8Array.of(0x06, 0x0a, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x63, 0x64, 0x06, 0x02, 0x01);
function holds(raw: Uint8Array, needle: Uint8Array): boolean {
  outer: for (let i = 0; i + needle.length <= raw.length; i++) {
    for (let j = 0; j < needle.length; j++) if (raw[i + j] !== needle[j]) continue outer;
    return true;
  }
  return false;
}

const decoder = new TextDecoder();
const fresh = (c: X509Certificate, at: number) => Date.parse(c.validFrom) <= at && at <= Date.parse(c.validTo);

/** The payload of a JWS Apple signed, or a refusal: ES256 only, a chain in `x5c` (leaf first) whose every link is
 * signed by the next and valid now, ending at a root the operator pinned (the chain's own last certificate, or one a
 * pinned root signed), carrying Apple's two extensions; the signature made by the leaf. */
export async function verifySigned(jws: unknown, roots: readonly string[], now: number): Promise<Record<string, unknown>> {
  const refuse = (why: string) => new AppStoreRefused(403, `signed data refused: ${why}`);
  if (typeof jws !== "string" || jws.length > RULES.bodyLimits.appstore) throw new AppStoreRefused(400, "signed data required");
  const parts = jws.split(".");
  if (parts.length !== 3) throw new AppStoreRefused(400, "signed data is a JWS");
  let head: { alg?: unknown; x5c?: unknown }, payload: unknown, signature: Uint8Array<ArrayBuffer>;
  try {
    head = JSON.parse(decoder.decode(fromBase64url(parts[0])));
    payload = JSON.parse(decoder.decode(fromBase64url(parts[1])));
    signature = fromBase64url(parts[2]);
  } catch {
    throw new AppStoreRefused(400, "signed data is a JWS");
  }
  if (head.alg !== "ES256") throw refuse("algorithm");
  if (!Array.isArray(head.x5c) || head.x5c.length < 2 || head.x5c.length > 4 || !head.x5c.every((c) => typeof c === "string")) throw refuse("certificate chain");
  let chain: X509Certificate[];
  try {
    chain = (head.x5c as string[]).map((c) => new X509Certificate(Uint8Array.from(atob(c), (ch) => ch.charCodeAt(0))));
  } catch {
    throw refuse("certificate chain");
  }
  if (!chain.every((c) => fresh(c, now))) throw refuse("a certificate is not valid now");
  for (let i = 0; i + 1 < chain.length; i++) {
    if (!chain[i].verify(chain[i + 1].publicKey)) throw refuse("certificate chain");
  }
  const top = chain[chain.length - 1];
  const pinned = roots.map((r) => new X509Certificate(r));
  const anchored = pinned.some((r) => (r.raw.equals(top.raw) && fresh(r, now)) || (fresh(r, now) && r.ca && top.verify(r.publicKey)));
  if (!anchored) throw refuse("not Apple's root");
  if (!holds(chain[0].raw, LEAF_OID) || !holds(chain[1].raw, INTERMEDIATE_OID) || !chain[1].ca) throw refuse("not Apple's signing certificates");
  let ok = false;
  try {
    const spki = new Uint8Array(chain[0].publicKey.export({ format: "der", type: "spki" }));
    const key = await crypto.subtle.importKey("spki", spki, { name: "ECDSA", namedCurve: "P-256" }, false, ["verify"]);
    ok = await crypto.subtle.verify({ name: "ECDSA", hash: "SHA-256" }, key, signature, new TextEncoder().encode(`${parts[0]}.${parts[1]}`));
  } catch { /* a key that is not P-256, a signature of the wrong shape: refused below */ }
  if (!ok) throw refuse("signature");
  if (typeof payload !== "object" || payload === null || Array.isArray(payload)) throw new AppStoreRefused(400, "signed data is an object");
  return payload as Record<string, unknown>;
}

/** What the broker reads of Apple's JWSTransactionDecodedPayload. */
export interface Transaction {
  transactionId: string;
  originalTransactionId: string;
  bundleId: string;
  productId: string;
  environment: string;
  /** The account's uuid, set by the app at purchase (Product.PurchaseOption.appAccountToken). */
  appAccountToken: string | null;
  /** Milliseconds. */
  expiresDate: number | null;
  revocationDate: number | null;
}

export function transactionOf(payload: Record<string, unknown>): Transaction {
  const str = (v: unknown) => typeof v === "string" && v.length > 0 && v.length <= 255 ? v : null;
  const num = (v: unknown) => Number.isFinite(v) ? v as number : null;
  const transactionId = str(payload.transactionId), originalTransactionId = str(payload.originalTransactionId);
  const bundleId = str(payload.bundleId), productId = str(payload.productId), environment = str(payload.environment);
  if (!transactionId || !originalTransactionId || !bundleId || !productId || !environment) throw new AppStoreRefused(400, "the transaction is incomplete");
  const token = typeof payload.appAccountToken === "string" ? payload.appAccountToken.toLowerCase() : null;
  return {
    transactionId, originalTransactionId, bundleId, productId, environment, appAccountToken: token === null ? null : accountOf(token),
    expiresDate: num(payload.expiresDate), revocationDate: num(payload.revocationDate),
  };
}

/** The app a transaction belongs to, and its plan, or a refusal: only a bundle the operator tied to a tenant, in an
 * environment it counts, selling a product it maps to a plan. */
export function appOf(config: AppStoreConfig, tx: { bundleId: string; environment: string; productId?: string }): { app: AppStoreApp; plan: string | null } {
  const app = config.apps.find((a) => a.bundleId === tx.bundleId);
  if (!app) throw new AppStoreRefused(403, "bundle refused");
  if (!(tx.environment === "Production" || (tx.environment === "Sandbox" && app.sandbox))) throw new AppStoreRefused(403, "environment refused");
  const plan = tx.productId !== undefined && Object.hasOwn(app.products, tx.productId) ? app.products[tx.productId] : null;
  return { app, plan };
}

const API = { Production: "https://api.storekit.itunes.apple.com", Sandbox: "https://api.storekit-sandbox.itunes.apple.com" } as const;
/** App Store Server API's subscription status: 1 is active; 2 expired, 3 in billing retry, 4 in grace period, 5 revoked.
 * Only an active subscription holds a plan, as only an active or trialing Stripe one does (core.ts's entitlementOf). */
const ACTIVE = 1;

function der(pem: string): Uint8Array<ArrayBuffer> {
  return Uint8Array.from(atob(pem.replace(/-----[A-Z ]+-----|\s/g, "")), (c) => c.charCodeAt(0));
}

/** The subscription's transactions as Apple holds them now, each with its status: read from the Server API with the
 * operator's key, every transaction in the answer checked as any other signed data. */
export async function statusOf(p: {
  config: AppStoreConfig; app: AppStoreApp; originalTransactionId: string; environment: "Production" | "Sandbox"; fetcher: typeof fetch; now: number;
}): Promise<(Transaction & { status: number })[]> {
  const key = await crypto.subtle.importKey("pkcs8", der(p.config.key), { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
  const iat = Math.floor(p.now / 1000);
  const token = await signEs256(key, p.config.keyId, { iss: p.config.issuerId, iat, exp: iat + 300, aud: "appstoreconnect-v1", bid: p.app.bundleId });
  let res: Response;
  try {
    res = await p.fetcher(`${API[p.environment]}/inApps/v1/subscriptions/${encodeURIComponent(p.originalTransactionId)}`, {
      headers: { authorization: `Bearer ${token}` }, redirect: "manual", signal: AbortSignal.timeout(10_000),
    });
  } catch {
    throw new AppStoreRefused(502, "the App Store is unavailable");
  }
  if (res.status !== 200) {
    await res.body?.cancel();
    console.error(`billing: App Store Server API answered ${res.status}`);
    throw new AppStoreRefused(502, "the App Store is unavailable");
  }
  const text = await readCapped(res.body, 262144, res.headers.get("content-length"));
  let doc: { data?: { lastTransactions?: { status?: unknown; signedTransactionInfo?: unknown }[] }[] };
  try {
    doc = JSON.parse(text ?? "");
  } catch {
    throw new AppStoreRefused(502, "the App Store's answer is unreadable");
  }
  const out: (Transaction & { status: number })[] = [];
  for (const group of doc.data ?? []) {
    for (const last of group.lastTransactions ?? []) {
      let tx: Transaction;
      try {
        tx = transactionOf(await verifySigned(last.signedTransactionInfo, p.config.roots, p.now));
      } catch (e) {
        // Apple's own answer failing its signature is the channel's fault, never the player's.
        console.error(`billing: App Store Server API answer refused: ${e instanceof Error ? e.message : e}`);
        throw new AppStoreRefused(502, "the App Store's answer was refused");
      }
      if (tx.bundleId !== p.app.bundleId || tx.environment !== p.environment || !Number.isInteger(last.status)) continue;
      out.push({ ...tx, status: last.status as number });
    }
  }
  return out;
}

/** What the App Store holds for one account and plan, from a read of Apple: active while a transaction of the plan
 * bought for this account is in an active subscription, not revoked and not yet expired, through the latest end. */
export function heldOf(txs: readonly (Transaction & { status: number })[], app: AppStoreApp, account: string, plan: string, now: number): { active: boolean; through: number } {
  let through = 0;
  for (const tx of txs) {
    if (tx.appAccountToken !== account || app.products[tx.productId] !== plan) continue;
    if (tx.status !== ACTIVE || tx.revocationDate !== null || tx.expiresDate === null || tx.expiresDate <= now) continue;
    through = Math.max(through, Math.floor(tx.expiresDate / 1000));
  }
  return { active: through > 0, through };
}

/** Stripe's held entitlement and the App Store's, as one: held if either holds, to the later end. */
export function merged(a: { active: boolean; through: number }, b: { active: boolean; through: number } | null): { active: boolean; through: number } {
  if (!b) return a;
  const through = Math.max(a.active ? a.through : 0, b.active ? b.through : 0);
  return { active: through > 0, through };
}

// How long what Apple said stays after the subscription's end: a notification arrives, or the account asks again, well
// before; past it the broker holds nothing for the account, which is what a lapsed subscription is.
const AFTER_END_MS = 90 * 86_400_000;
const keyOf = (t: string, account: string, plan: string) => `${t} ${account} ${plan}`;

export function appstore(p: { config: AppStoreConfig; store: Store; fetcher: typeof fetch; now?: () => number }) {
  const now = p.now ?? Date.now;
  return {
    config: p.config,
    now,
    /** What the App Store holds for an account's plan, as last read, or null where it has said nothing. */
    async heldBy(t: string, account: string, plan: string): Promise<{ active: boolean; through: number } | null> {
      const text = await p.store.recall("appstore held", keyOf(t, account, plan));
      if (text === null) return null;
      const through = Number(JSON.parse(text).through);
      return { active: through * 1000 > now(), through: through * 1000 > now() ? through : 0 };
    },
    /** Reads the subscription again from Apple and keeps what it holds for the account's plan. A transaction bought
     * for another account is refused: it is the account the app named at purchase that gets the plan. */
    async refresh(app: AppStoreApp, tx: Transaction, account: string, plan: string): Promise<{ active: boolean; through: number }> {
      if (tx.appAccountToken !== account) throw new AppStoreRefused(403, "the transaction is another account's");
      const at = now();
      const txs = await statusOf({
        config: p.config, app, originalTransactionId: tx.originalTransactionId, environment: tx.environment as "Production" | "Sandbox", fetcher: p.fetcher, now: at,
      });
      const held = heldOf(txs, app, account, plan, at);
      await p.store.remember("appstore held", keyOf(app.tenant, account, plan), (held.active ? held.through * 1000 - at : 0) + AFTER_END_MS, JSON.stringify({ through: held.through }));
      return held;
    },
  };
}
export type AppStore = ReturnType<typeof appstore>;
