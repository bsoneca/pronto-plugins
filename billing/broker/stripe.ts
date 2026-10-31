// The little of Stripe's API the broker speaks: form-encoded requests under
// one pinned API version, JSON ones under another for the /v2 namespace
// connected accounts live in, and the signature Stripe puts on a webhook.

/** The API version every /v1 request names, so a subscription's period end
 * is where the broker reads it whatever the account's default. */
export const STRIPE_VERSION = "2024-06-20";
/** The version every /v2 request must name: Stripe opens new platforms'
 * connected accounts through /v2/core/accounts only. */
export const STRIPE_V2_VERSION = "2026-09-30.endive";

/** Stripe's bracketed form encoding of nested objects and arrays. */
export function form(params: Record<string, unknown>): URLSearchParams {
  const out = new URLSearchParams();
  const put = (key: string, v: unknown) => {
    if (v === undefined || v === null) return;
    if (Array.isArray(v)) v.forEach((x, i) => put(`${key}[${i}]`, x));
    else if (typeof v === "object") for (const [k, x] of Object.entries(v)) put(`${key}[${k}]`, x);
    else out.append(key, String(v));
  };
  for (const [k, v] of Object.entries(params)) put(k, v);
  return out;
}

export class StripeError extends Error {
  constructor(readonly status: number, readonly code: string, message: string) {
    super(message);
  }
}

export type Stripe = <T = Record<string, unknown>>(
  method: "GET" | "POST",
  path: string,
  params?: Record<string, unknown>,
  idempotencyKey?: string,
) => Promise<T>;

export function stripe(p: { key: string; api?: string; fetcher?: typeof fetch }): Stripe {
  const api = (p.api ?? "https://api.stripe.com").replace(/\/$/, "");
  const fetcher = p.fetcher ?? fetch;
  return async (method, path, params = {}, idempotencyKey) => {
    // A /v2 request posts JSON; its query is form-encoded as /v1's is.
    const v2 = path.startsWith("/v2/");
    const query = form(params);
    const url = method === "GET" ? `${api}${path}?${query}` : `${api}${path}`;
    const res = await fetcher(url, {
      method,
      headers: {
        authorization: `Bearer ${p.key}`,
        "stripe-version": v2 ? STRIPE_V2_VERSION : STRIPE_VERSION,
        ...(method === "POST" ? { "content-type": v2 ? "application/json" : "application/x-www-form-urlencoded" } : {}),
        ...(idempotencyKey ? { "idempotency-key": idempotencyKey } : {}),
      },
      ...(method === "POST" ? { body: v2 ? JSON.stringify(params) : query } : {}),
    });
    const data = await res.json();
    if (!res.ok) throw new StripeError(res.status, data?.error?.code ?? data?.error?.type ?? "error", data?.error?.message ?? `stripe ${res.status}`);
    return data;
  };
}

const enc = new TextEncoder();
const hex = (b: ArrayBuffer) => [...new Uint8Array(b)].map((x) => x.toString(16).padStart(2, "0")).join("");

async function hmacHex(secret: string, text: string): Promise<string> {
  const key = await crypto.subtle.importKey("raw", enc.encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  return hex(await crypto.subtle.sign("HMAC", key, enc.encode(text)));
}

/** The Stripe-Signature header for `payload` at `t`, as Stripe writes it. */
export const signWebhook = async (secret: string, payload: string, t = Math.floor(Date.now() / 1000)) =>
  `t=${t},v1=${await hmacHex(secret, `${t}.${payload}`)}`;

/** Whether a webhook's body was signed by Stripe with this endpoint's secret,
 * within `tolerance` seconds of now. */
export async function webhookSigned(secret: string, payload: string, header: string | null, tolerance = 300, now = Math.floor(Date.now() / 1000)): Promise<boolean> {
  if (!header) return false;
  const parts = header.split(",").map((x) => x.split("=", 2) as [string, string]);
  const t = Number(parts.find(([k]) => k === "t")?.[1]);
  if (!Number.isInteger(t) || Math.abs(now - t) > tolerance) return false;
  const want = await hmacHex(secret, `${t}.${payload}`);
  let ok = false;
  for (const [k, v] of parts) if (k === "v1" && v.length === want.length) {
    let d = 0;
    for (let i = 0; i < v.length; i++) d |= v.charCodeAt(i) ^ want.charCodeAt(i);
    ok ||= d === 0;
  }
  return ok;
}
