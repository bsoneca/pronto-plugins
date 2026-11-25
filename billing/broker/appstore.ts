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
  /** The API key, imported when the configuration is read: a .p8 that is no P-256 key stops the broker at start. */
  key: CryptoKey;
}

/** An App Store Connect .p8 (PKCS8 PEM) as a signing key. */
export const importApiKey = (pem: string): Promise<CryptoKey> =>
  crypto.subtle.importKey("pkcs8", der(pem), { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);

/** The configuration from the broker's environment, or undefined when APPSTORE_APPS is not set (the App Store is off).
 * Set, it must be whole and valid: a half-configured broker would take a transaction it cannot check, so it refuses to start. */
export async function appstoreConfigFrom(env: (k: string) => string | undefined): Promise<AppStoreConfig | undefined> {
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
  let key: CryptoKey;
  try {
    key = await importApiKey(env("APPSTORE_KEY")!);
  } catch {
    throw new Error("APPSTORE_KEY is an App Store Connect .p8: a PKCS8 PEM of a P-256 key");
  }
  return { apps, roots, issuerId: env("APPSTORE_ISSUER_ID")!, keyId: env("APPSTORE_KEY_ID")!, key };
}

/** A sandbox app (its sandbox purchases count) may be served only by a broker that holds its tenant in Stripe's sandbox too: on a live
 * one, a rehearsal build's free purchases would grant a live tenant's plan. `sandboxTenants` is BILLING_SANDBOX_TENANTS's pattern. */
export function checkSandboxApps(config: Pick<AppStoreConfig, "apps">, sandboxTenants: RegExp | null): void {
  for (const a of config.apps) {
    if (a.sandbox && !(sandboxTenants && sandboxTenants.test(a.tenant))) {
      throw new Error(`APPSTORE_APPS ${a.bundleId} has sandbox: true, but its tenant ${a.tenant} is not one BILLING_SANDBOX_TENANTS holds in the sandbox: a live tenant takes no sandbox purchases`);
    }
  }
}

// The extensions Apple puts on the certificates that sign App Store data: on the leaf 1.2.840.113635.100.6.11.1 and on the
// intermediate 1.2.840.113635.100.6.2.1 (the OID's content bytes, hex). Any certificate the same intermediate issued for another
// purpose (an app developer's own, say) lacks the first, and signs no transaction. Read from the certificate's extensions by their
// extnID, never by searching its bytes: those bytes can also sit inside another extension's value, which a requester may choose.
const LEAF_OID = "2a864886f76364060b01";
const INTERMEDIATE_OID = "2a864886f76364060201";
const BASIC_CONSTRAINTS_OID = "551d13";

interface Tlv { tag: number; start: number; end: number }
/** One DER element at `at` within `buf`, or a refusal when it runs past `end`. */
function tlv(buf: Uint8Array, at: number, end = buf.length): Tlv {
  if (at + 2 > end) throw new Error("der");
  const tag = buf[at];
  let len = buf[at + 1], start = at + 2;
  if (len & 0x80) {
    const n = len & 0x7f;
    if (n < 1 || n > 4 || start + n > end) throw new Error("der");
    len = 0;
    for (let i = 0; i < n; i++) len = len * 256 + buf[start + i];
    start += n;
  }
  if (start + len > end) throw new Error("der");
  return { tag, start, end: start + len };
}
const children = (buf: Uint8Array, e: Tlv): Tlv[] => {
  const out: Tlv[] = [];
  for (let at = e.start; at < e.end;) {
    const c = tlv(buf, at, e.end);
    out.push(c);
    at = c.end;
  }
  return out;
};
const hex = (buf: Uint8Array, e: Tlv) => Array.from(buf.subarray(e.start, e.end), (b) => b.toString(16).padStart(2, "0")).join("");

/** A certificate's extensions (tbsCertificate [3]): each extnID as hex, with its value (the OCTET STRING's content). A certificate that
 * does not parse as X.509 DER throws, and is refused by the caller. */
function extensionsOf(raw: Uint8Array): { id: string; value: Tlv }[] {
  const tbs = children(raw, tlv(raw, 0))[0];
  const block = children(raw, tbs).find((f) => f.tag === 0xa3);
  if (!block) return [];
  const list = children(raw, block)[0];
  const out: { id: string; value: Tlv }[] = [];
  for (const ext of children(raw, list)) {
    const [oid, ...rest] = children(raw, ext);
    const value = rest.at(-1);
    if (oid?.tag !== 0x06 || value?.tag !== 0x04) throw new Error("der");
    out.push({ id: hex(raw, oid), value });
  }
  return out;
}
const hasExtension = (raw: Uint8Array, id: string) => extensionsOf(raw).some((e) => e.id === id);

/** A certificate's basicConstraints: whether it is a CA, and the most CAs that may follow it (pathLenConstraint) where it says. */
function constraintsOf(raw: Uint8Array): { ca: boolean; pathLen: number | null } {
  const ext = extensionsOf(raw).find((e) => e.id === BASIC_CONSTRAINTS_OID);
  if (!ext) return { ca: false, pathLen: null };
  let ca = false, pathLen: number | null = null;
  for (const f of children(raw, tlv(raw, ext.value.start, ext.value.end))) {
    if (f.tag === 0x01) ca = raw[f.start] !== 0;
    else if (f.tag === 0x02) pathLen = Array.from(raw.subarray(f.start, f.end)).reduce((n, b) => n * 256 + b, 0);
  }
  return { ca, pathLen };
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
  // The leaf is no CA and every certificate above it is one; a pathLenConstraint bounds the CAs below it.
  let constraints: { ca: boolean; pathLen: number | null }[];
  try {
    constraints = chain.map((c) => constraintsOf(c.raw));
  } catch {
    throw refuse("certificate chain");
  }
  const within = (c: { ca: boolean; pathLen: number | null }, below: number) => c.ca && (c.pathLen === null || c.pathLen >= below);
  if (constraints[0].ca || !constraints.slice(1).every((c, i) => within(c, i))) throw refuse("certificate constraints");
  const top = chain[chain.length - 1];
  const pinned = roots.map((r) => new X509Certificate(r));
  // A pinned root that signed the chain's last certificate: the CAs below it are the chain's intermediates.
  let anchored = false;
  try {
    anchored = pinned.some((r) => fresh(r, now) && (r.raw.equals(top.raw) || (within(constraintsOf(r.raw), chain.length - 1) && top.verify(r.publicKey))));
  } catch { /* a root that does not parse anchors nothing */ }
  if (!anchored) throw refuse("not Apple's root");
  let signing: boolean;
  try {
    signing = hasExtension(chain[0].raw, LEAF_OID) && hasExtension(chain[1].raw, INTERMEDIATE_OID);
  } catch {
    throw refuse("certificate chain");
  }
  if (!signing) throw refuse("not Apple's signing certificates");
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
 * An active subscription holds a plan, as an active or trialing Stripe one does (core.ts's entitlementOf); one in its grace period
 * (Apple keeps trying to charge a paying player, and asks the app to keep serving) holds it until the grace ends. Billing retry
 * (after the grace, or with none), expired and revoked hold nothing. */
const ACTIVE = 1, GRACE = 4;

function der(pem: string): Uint8Array<ArrayBuffer> {
  return Uint8Array.from(atob(pem.replace(/-----[A-Z ]+-----|\s/g, "")), (c) => c.charCodeAt(0));
}

/** The subscription's transactions as Apple holds them now, each with its status: read from the Server API with the
 * operator's key, every transaction in the answer checked as any other signed data. */
export async function statusOf(p: {
  config: AppStoreConfig; app: AppStoreApp; originalTransactionId: string; environment: "Production" | "Sandbox"; fetcher: typeof fetch; now: number;
}): Promise<(Transaction & { status: number; graceUntil: number | null })[]> {
  const iat = Math.floor(p.now / 1000);
  const token = await signEs256(p.config.key, p.config.keyId, { iss: p.config.issuerId, iat, exp: iat + 300, aud: "appstoreconnect-v1", bid: p.app.bundleId });
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
  let doc: { data?: { lastTransactions?: { status?: unknown; signedTransactionInfo?: unknown; signedRenewalInfo?: unknown }[] }[] };
  try {
    doc = JSON.parse(text ?? "");
  } catch {
    throw new AppStoreRefused(502, "the App Store's answer is unreadable");
  }
  const out: (Transaction & { status: number; graceUntil: number | null })[] = [];
  for (const group of doc.data ?? []) {
    for (const last of group.lastTransactions ?? []) {
      let tx: Transaction, graceUntil: number | null = null;
      try {
        tx = transactionOf(await verifySigned(last.signedTransactionInfo, p.config.roots, p.now));
        // In a grace period (status 4) the renewal info, signed as any other, says when the grace ends.
        if (last.status === GRACE) {
          const grace = last.signedRenewalInfo === undefined ? null : (await verifySigned(last.signedRenewalInfo, p.config.roots, p.now)).gracePeriodExpiresDate;
          graceUntil = Number.isFinite(grace) ? grace as number : null;
        }
      } catch (e) {
        // Apple's own answer failing its signature is the channel's fault, never the player's.
        console.error(`billing: App Store Server API answer refused: ${e instanceof Error ? e.message : e}`);
        throw new AppStoreRefused(502, "the App Store's answer was refused");
      }
      if (tx.bundleId !== p.app.bundleId || tx.environment !== p.environment || !Number.isInteger(last.status)) continue;
      out.push({ ...tx, status: last.status as number, graceUntil });
    }
  }
  return out;
}

/** What the App Store holds for one account and plan, from a read of Apple: active while a transaction of the plan bought for this
 * account is in an active subscription, not revoked and not yet expired, or in its grace period (through the grace's end), to the
 * latest end. */
export function heldOf(txs: readonly (Transaction & { status: number; graceUntil?: number | null })[], app: AppStoreApp, account: string, plan: string, now: number): { active: boolean; through: number } {
  let through = 0;
  for (const tx of txs) {
    if (tx.appAccountToken !== account || app.products[tx.productId] !== plan) continue;
    if (tx.revocationDate !== null) continue;
    const end = tx.status === ACTIVE ? tx.expiresDate : tx.status === GRACE ? tx.graceUntil ?? null : null;
    if (end === null || end <= now) continue;
    through = Math.max(through, Math.floor(end / 1000));
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
