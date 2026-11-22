import { AsyncLocalStorage } from "node:async_hooks";
import { json, readCapped } from "../shared.ts";
import { RULES } from "../rules.ts";
import { DoorError, doorKey, throughDoor as callDoor } from "./door.ts";

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

/** No try of a call to Stripe, direct or through the door, waits longer: a webhook's claim on its event
 * (main.ts EVENT_LEASE_MS) is sized past it. */
export const CALL_TIMEOUT_MS = 15_000;

/** Which way a call to Stripe goes: straight with the broker's key, or through the airlock's door. */
export type Route = "direct" | "door";
/** A client that can say which way its calls go now. A client without it (the stand-in) goes neither way. */
export type Routed = Stripe & { route?: () => Promise<Route> };

/** A key the airlock's door takes (A-Z a-z 0-9 . _ : -, at most 200): the broker's own key hashed, so
 * two keys stay two, and a call with none gets one of its own, so every call through the door is in
 * its ledger once. */
async function callKey(idempotencyKey: string | undefined): Promise<string> {
  if (idempotencyKey === undefined) return `call-${crypto.randomUUID()}`;
  return await doorKey("key", idempotencyKey);
}

/** Stripe through the airlock's door (PRONTO-135): the airlock holds the key and adds it, records
 * every call in its ledger under its idempotency key, and answers Stripe's status and body. `door`
 * is the door's URL, `http://billing-airlock:9998/door/stripe`. */
function throughDoor(door: string, fetcher: typeof fetch): Stripe {
  return async (method, path, params = {}, idempotencyKey) => {
    const v2 = path.startsWith("/v2/");
    const query = form(params);
    const key = await callKey(idempotencyKey);
    const request = {
      key,
      ...(idempotencyKey === undefined ? {} : { sinkKey: idempotencyKey }),
      method,
      path: method === "GET" && `${query}` !== "" ? `${path}?${query}` : path,
      ...(method === "POST" ? (v2 ? { body: params, contentType: "application/json" } : { body: `${query}`, contentType: "application/x-www-form-urlencoded" }) : {}),
      headers: { "Stripe-Version": v2 ? STRIPE_V2_VERSION : STRIPE_VERSION },
    };
    let answer;
    try {
      answer = await callDoor(door, request, ((u, init) => fetcher(u, { ...init, signal: AbortSignal.timeout(CALL_TIMEOUT_MS) })) as typeof fetch);
    } catch (e) {
      if (e instanceof DoorError) throw new StripeError(e.status, "airlock", e.message);
      throw e;
    }
    const { status, body } = answer as { status: number; body: Record<string, unknown> & { error?: { code?: string; type?: string; message?: string } } };
    if (status >= 300) throw new StripeError(status, body?.error?.code ?? body?.error?.type ?? "error", body?.error?.message ?? `stripe ${status}`);
    return body as never;
  };
}

/** What the request being answered says of its caller: the account it names, and whether the
 * tenant's flag sends that account's Stripe calls through the airlock's door (PRONTO-218: the tenant's
 * billing service asks its flagd with the reader's own session and says `door`). Neither, for what
 * names no account (Stripe's webhook, say). Set by `forAccount` around the broker's handler. */
const caller = new AsyncLocalStorage<{ account?: string; door?: boolean; transport?: Route }>();

/** Notes, on the request being answered, the transport that answered a call to Stripe (a client's own word,
 * made once the call has answered). A call outside a request notes nothing. */
export const markTransport = (route: Route): void => {
  const who = caller.getStore();
  if (who) who.transport = route;
};

/** The transport of the last call this request made to Stripe: undefined when it made none. */
export const transportUsed = (): Route | undefined => caller.getStore()?.transport;

/** Runs `handler` with transport tracking on and nothing read of the request: for a broker that goes one way
 * (direct only, or door only), whose /probe must still say which transport answered. */
export function tracked<A extends unknown[]>(handler: (req: Request, ...rest: A) => Promise<Response>) {
  return (req: Request, ...rest: A): Promise<Response> => caller.run({}, () => handler(req, ...rest));
}

/** A body this size or under is read for its caller, declared or not, once: the handler is handed
 * the same text (no copy whose cancelling would wait on the handler's read). A larger one is handed
 * on empty, which the handler's own capped read makes of it anyway, and says nothing here. Stripe's
 * webhook (/stripe) names no caller and is never read here. */
const BODY_PATHS = ["/checkout", "/trial/offer", "/trial/checkout", "/portal", "/resync", "/onboard", "/probe", "/route"];

/** The most of a request's body the broker reads, from rules.cue (bodyLimits, routeLimits.bodyMax): the webhook's, the
 * route probe's, or the ordinary request's; undefined for a path that reads no body. One owner for the dispatcher
 * and the caller wrapper. */
export function bodyLimitOf(method: string, path: string): number | undefined {
  if (method !== "POST") return undefined;
  if (path === "/stripe") return RULES.bodyLimits.webhook;
  if (path === "/route") return RULES.routeLimits.bodyMax;
  return BODY_PATHS.includes(path) ? RULES.bodyLimits.request : undefined;
}

/** Reads the capped body of `req` once, and hands back a request that carries the text already read, or a 413 the
 * moment the cap is passed (the rest of a client's stream is not read). A request with no body path is returned as is. */
export async function withCappedBody(req: Request): Promise<Request | Response> {
  const limit = bodyLimitOf(req.method, new URL(req.url).pathname);
  if (limit === undefined) return req;
  const text = await readCapped(req.body, limit, req.headers.get("content-length"));
  if (text === null) return json(413, { error: "too large" });
  const headers = new Headers(req.headers);
  headers.delete("content-length");
  return new Request(req.url, { method: req.method, headers, body: text, signal: req.signal });
}

/** Runs `handler` with what its request's JSON body says of its caller (`account`, `door`). */
export function forAccount<A extends unknown[]>(handler: (req: Request, ...rest: A) => Promise<Response>) {
  return async (req: Request, ...rest: A): Promise<Response> => {
    const who: { account?: string; door?: boolean } = {};
    if (req.method === "POST" && new URL(req.url).pathname !== "/stripe") {
      // The body is read once, up to the CUE limit; past it the answer is a 413 at once.
      const capped = await withCappedBody(req);
      if (capped instanceof Response) return capped;
      req = capped;
      const text = await req.text();
      if ((req.headers.get("content-type") ?? "").startsWith("application/json")) {
        try {
          const b = JSON.parse(text);
          if (typeof b?.account === "string" && b.account) who.account = b.account;
          if (typeof b?.door === "boolean") who.door = b.door;
        } catch { /* not JSON: nothing said, and the handler refuses it as before */ }
      }
      req = new Request(req.url, { method: req.method, headers: req.headers, body: text, signal: req.signal });
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
  // Both ways send Stripe the broker's own key: the direct way as before the door, the door as its
  // `sinkKey` (its ledger keeps a hashed one), so a call retried the other way across a flip is one.
  // The one selection: a call's transport and the route probe's answer are both this function's, never two
  // computations that could differ.
  const choose = (): Route => p.on() ? "door" : "direct";
  const s: Routed = async (method, path, params, idempotencyKey) => {
    const route = choose();
    const answer = await (route === "door" ? p.door : p.direct)(method, path, params, idempotencyKey);
    markTransport(route);
    return answer as never;
  };
  s.route = () => Promise.resolve<Route>(choose());
  return s;
}

export function stripe(p: { key: string; api?: string; fetcher?: typeof fetch } | { door: string; fetcher?: typeof fetch }): Routed {
  if ("door" in p) {
    const through = throughDoor(p.door, p.fetcher ?? fetch);
    const viaDoor: Routed = async (method, path, params, idempotencyKey) => {
      const answer = await through(method, path, params, idempotencyKey);
      markTransport("door");
      return answer as never;
    };
    return Object.assign(viaDoor, { route: () => Promise.resolve<Route>("door") });
  }
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
      signal: AbortSignal.timeout(CALL_TIMEOUT_MS),
    });
    const data = await res.json();
    if (!res.ok) throw new StripeError(res.status, data?.error?.code ?? data?.error?.type ?? "error", data?.error?.message ?? `stripe ${res.status}`);
    markTransport("direct");
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
