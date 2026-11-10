import { AsyncLocalStorage } from "node:async_hooks";
import { readCapped } from "../shared.ts";

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
  method: "GET" | "POST" | "DELETE",
  path: string,
  params?: Record<string, unknown>,
  idempotencyKey?: string,
) => Promise<T>;

/** Which way a call to Stripe goes: straight with the broker's key, or through the airlock's door. */
export type Route = "direct" | "door";
/** A client that can say which way its calls go now. A client without it (the stand-in) goes neither way. */
export type Routed = Stripe & { route?: () => Promise<Route> };

/** A key the airlock's door takes (A-Z a-z 0-9 . _ : -, at most 200): the broker's own key hashed, so
 * two keys stay two, and a call with none gets one of its own, so every call through the door is in
 * its ledger once. */
async function doorKey(idempotencyKey: string | undefined): Promise<string> {
  if (idempotencyKey === undefined) return `call-${crypto.randomUUID()}`;
  return `key-${hex(await crypto.subtle.digest("SHA-256", enc.encode(idempotencyKey)))}`;
}

/** How often a call the door could not answer (502: Stripe answered 5xx, or nothing) is made again,
 * with the same key, which Stripe's idempotency makes safe. */
const DOOR_TRIES = 3;

/** Stripe through the airlock's door (PRONTO-135): the airlock holds the key and adds it, records
 * every call in its ledger under its idempotency key, and answers Stripe's status and body. `door`
 * is the door's URL, `http://billing-airlock:9998/door/stripe`. */
function throughDoor(door: string, fetcher: typeof fetch): Stripe {
  return async (method, path, params = {}, idempotencyKey) => {
    const v2 = path.startsWith("/v2/");
    const query = form(params);
    const key = await doorKey(idempotencyKey);
    const request = {
      key,
      method,
      path: method === "GET" && `${query}` !== "" ? `${path}?${query}` : path,
      ...(method === "POST" ? (v2 ? { body: params, contentType: "application/json" } : { body: `${query}`, contentType: "application/x-www-form-urlencoded" }) : {}),
      headers: { "Stripe-Version": v2 ? STRIPE_V2_VERSION : STRIPE_VERSION },
    };
    for (let i = 1;; i++) {
      const res = await fetcher(door, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(request) });
      const answer = await res.json();
      if (res.status === 502 && i < DOOR_TRIES) {
        await new Promise((r) => setTimeout(r, 250 * 2 ** i));
        continue;
      }
      if (res.status !== 200) throw new StripeError(res.status, "airlock", `airlock door: ${res.status} ${answer?.error ?? ""}`.trim());
      const { status, body } = answer as { status: number; body: Record<string, unknown> & { error?: { code?: string; type?: string; message?: string } } };
      if (status >= 300) throw new StripeError(status, body?.error?.code ?? body?.error?.type ?? "error", body?.error?.message ?? `stripe ${status}`);
      return body as never;
    }
  };
}

/** What the request being answered says of its caller: the account it names, and whether the
 * tenant's flag sends that account's Stripe calls through the airlock's door (PRONTO-218: the tenant's
 * billing service asks its flagd with the reader's own session and says `door`). Neither, for what
 * names no account (Stripe's webhook, say). Set by `forAccount` around the broker's handler. */
const caller = new AsyncLocalStorage<{ account?: string; door?: boolean }>();

/** A body this size or under is read for its caller, declared or not (the handler's own capped read
 * takes the same); a larger one says nothing here, and that read refuses it as before. */
const CALLER_BODY_MAX = 4096;

/** Runs `handler` with what its request's JSON body says of its caller (`account`, `door`). */
export function forAccount<A extends unknown[]>(handler: (req: Request, ...rest: A) => Promise<Response>) {
  return async (req: Request, ...rest: A): Promise<Response> => {
    const who: { account?: string; door?: boolean } = {};
    if (req.method === "POST") {
      try {
        const text = await readCapped(req.clone().body, CALLER_BODY_MAX, req.headers.get("content-length"));
        const b = text ? JSON.parse(text) : null;
        if (typeof b?.account === "string" && b.account) who.account = b.account;
        if (typeof b?.door === "boolean") who.door = b.door;
      } catch { /* not JSON: nothing said */ }
    }
    return await caller.run(who, () => handler(req, ...rest));
  };
}

/** Whether the request being answered asked for the door: its tenant's word, read for each call. */
export const askedDoor = (): boolean => caller.getStore()?.door === true;

/** While the broker moves to the airlock's door (PRONTO-218): each call goes through the door when the
 * request asked for it (its tenant's flag), else straight to Stripe with the broker's key, as before.
 * A flag, not a deploy, moves it. */
export function switched(p: { direct: Stripe; door: Stripe; on: () => boolean }): Routed {
  // Both ways send Stripe the same idempotency key (the door's, which the airlock sends on), so a call
  // retried the other way is still the one call at Stripe.
  const s: Routed = async (method, path, params, idempotencyKey) =>
    p.on() ? await p.door(method, path, params, idempotencyKey) : await p.direct(method, path, params, idempotencyKey === undefined ? undefined : await doorKey(idempotencyKey));
  s.route = () => Promise.resolve<Route>(p.on() ? "door" : "direct");
  return s;
}

export function stripe(p: { key: string; api?: string; fetcher?: typeof fetch } | { door: string; fetcher?: typeof fetch }): Routed {
  if ("door" in p) return Object.assign(throughDoor(p.door, p.fetcher ?? fetch), { route: () => Promise.resolve<Route>("door") });
  const api = (p.api ?? "https://api.stripe.com").replace(/\/$/, "");
  const fetcher = p.fetcher ?? fetch;
  const direct: Routed = async (method, path, params = {}, idempotencyKey) => {
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
  direct.route = () => Promise.resolve<Route>("direct");
  return direct;
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
