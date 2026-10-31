// What a tenant checks of an entitlement the billing broker pushes: signed
// by the broker's key, issued by the broker it trusts, addressed to this
// tenant alone, unexpired, about one of its accounts.
import { fromBase64url, type Jwk, type KeySource, Refused } from "./shared.ts";

export interface Entitlement {
  account: string;
  plan: string;
  active: boolean;
  /** Paid through, in seconds since the epoch; 0 when nothing is. */
  through: number;
  /** What the account presents to manage its subscriptions. */
  manage: string;
  /** Newer than every entitlement before it for this account and plan. */
  ver: number;
}

const enc = new TextEncoder();

export async function verifyEntitlement(token: string, p: { issuer: string; tenant: string; keys: KeySource; now?: number }): Promise<Entitlement> {
  const parts = token.trim().split(".");
  if (parts.length !== 3) throw new Refused("entitlement malformed");
  let header: { alg?: string; kid?: string }, c: Record<string, unknown>;
  try {
    header = JSON.parse(new TextDecoder().decode(fromBase64url(parts[0])));
    c = JSON.parse(new TextDecoder().decode(fromBase64url(parts[1])));
  } catch {
    throw new Refused("entitlement malformed");
  }
  if (header.alg !== "ES256" || typeof header.kid !== "string") throw new Refused("entitlement not ES256");
  const jwk = await p.keys(header.kid);
  if (!jwk) throw new Refused("entitlement key unknown");
  const key = await crypto.subtle.importKey("jwk", { kty: jwk.kty, crv: jwk.crv, x: jwk.x, y: jwk.y }, { name: "ECDSA", namedCurve: "P-256" }, false, ["verify"]);
  if (!(await crypto.subtle.verify({ name: "ECDSA", hash: "SHA-256" }, key, fromBase64url(parts[2]), enc.encode(`${parts[0]}.${parts[1]}`)))) {
    throw new Refused("entitlement signature");
  }
  const now = p.now ?? Math.floor(Date.now() / 1000);
  if (c.iss !== p.issuer.replace(/\/$/, "")) throw new Refused("entitlement issuer");
  if (c.aud !== p.tenant) throw new Refused("entitlement audience");
  if (typeof c.exp !== "number" || c.exp < now - 60) throw new Refused("entitlement expired");
  if (typeof c.sub !== "string" || typeof c.plan !== "string" || typeof c.manage !== "string") throw new Refused("entitlement claims");
  if (c.status !== "active" && c.status !== "lapsed") throw new Refused("entitlement status");
  if (typeof c.through !== "number" || typeof c.ver !== "number") throw new Refused("entitlement claims");
  return { account: c.sub, plan: c.plan, active: c.status === "active", through: c.through, manage: c.manage, ver: c.ver };
}

/** The broker's keys, fetched again for a key not held at most once a
 * minute: an unknown kid anyone may send costs the broker nothing more. */
export function brokerKeys(issuer: string, fetcher: typeof fetch = fetch, cooldownMs = 60_000, now = () => Date.now()): KeySource {
  let keys: Jwk[] = [];
  let fetched = -Infinity;
  return async (kid) => {
    const held = keys.find((k) => k.kid === kid);
    if (held || now() - fetched < cooldownMs) return held;
    fetched = now();
    const res = await fetcher(`${issuer.replace(/\/$/, "")}/jwks`, { signal: AbortSignal.timeout(10_000) });
    if (!res.ok) throw new Error(`jwks ${res.status}`);
    const text = await res.text();
    if (text.length > 65_536) throw new Error("jwks over 64 KB");
    keys = (JSON.parse(text) as { keys: Jwk[] }).keys ?? [];
    return keys.find((k) => k.kid === kid);
  };
}
