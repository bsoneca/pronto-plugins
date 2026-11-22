// pronto-billing's side of an app: a service beside the door that publishes
// what the app sells, takes the entitlements the operator's billing broker
// pushes into the app's database, and sends a signed-in account to pay or to
// manage what it pays for. It holds no secret: the broker's entitlements are
// checked against the broker's keys, a reader is who the REST gateway says
// the reader's own session is, and the database is written as the service
// through that gateway, by functions billing_spec's migration made.
import { brokerKeys, verifyEntitlement } from "./entitlement.ts";
import { readCapped, Refused } from "./shared.ts";
import { RULES } from "./rules.ts";

export interface Settings {
  /** The app's own origin: its tenant at the broker. */
  origin: string;
  /** The broker as readers reach it (its issuer), and as this service does. */
  broker: string;
  brokerInternal?: string;
  /** The REST gateway, and the service's token for it. */
  crud: string;
  serviceJwt: string;
  /** What /.well-known/pronto-billing.json publishes: the owner and the plans. */
  document: string;
  /** The author's grants, as billing_spec.cue declares them (billing_plugin.cue's #billingGrants). */
  grants?: string;
  /** Where the flags are asked (OFREP), the grants among them as the flag billing_grants: a flagd's
   * own origin; `mesh`, the app's flagd through the pod's dapr sidecar, as the door reaches it on a
   * node; or `origin`, the app's own door, whose /ofrep/ takes the account from a session alone, so a
   * per-account flag asked with none (the trial's, PRONTO-82) answers for no account there. */
  flags?: string;
  /** The flag that turns the free trial on, evaluated per account at `flags`; none, and a
   * document with a trial is all it takes. */
  trialFlag?: string;
  // The flag that sends this tenant's calls to Stripe through the operator's airlock (PRONTO-218):
  // asked for each request's own reader, its value told to the broker as `door`. Only a lookup that succeeds with
  // true sends the reader through the door; a lookup that fails or is slow goes direct, with a logged warning.
  doorFlag?: string;
  /** The name of a pronto-flags flag, asked of flagd as the door flag is. While it evaluates true the service
   * behaves strictly where it once did not: a failed grants write turns /billing/health 503 and is retried with
   * backoff, a grants write has a deadline and an unconfirmed one is redone, a trial whose flag cannot be asked fails
   * the request and a broker that does not know trials fails an offer. Unset, false or a failed lookup: the
   * behaviour this service had before, exactly. */
  strictFlag?: string;
  fetcher?: typeof fetch;
}

const json = (status: number, body: unknown) =>
  new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json", "cache-control": "no-store" } });

/** A failed answer's body on one line: an HTML page by its <title>, else its text with the tags
 * stripped and the whitespace collapsed, at most `max` characters. */
export function brief(body: string, max = 120): string {
  const title = /<title[^>]*>([\s\S]*?)<\/title>/i.exec(body)?.[1];
  const text = (title ?? body).replace(/<[^>]*>/g, " ").replace(/\s+/g, " ").trim();
  return text.length > max ? `${text.slice(0, max - 3)}...` : text;
}

// A neighbour that is not up yet: crud or flagd not listening (the connection refused), the gateway
// not serving (503), or serving without billing_grant until it reloads its schema (404, PGRST202).
export class NotReady extends Error {}

// Whether a failed call met a neighbour still starting: a connection refused (nothing listens there
// yet), never any other network error such as a name that does not resolve.
export function refused(e: unknown): boolean {
  const said = (x: unknown): string => x instanceof Error ? `${x.message} ${said(x.cause)}` : "";
  return e instanceof TypeError && /connection refused|ECONNREFUSED/i.test(said(e));
}

// What the grants loop does with a failed call. Billing starts before its neighbours listen, so its
// first calls can meet one still starting (a NotReady): the loop waits and retries until the startup
// window ends. Every other failure (a refused token, an SQL error, a flag that holds no grants, an
// address that does not resolve), a NotReady past the window and any failure after one success is a
// "fail": the grants are not written, /billing/health answers 503 and the error is logged each time.
export const grantsWindowMs = 60_000;
// What the grants loop logs of a failed call when the strict flag is off (the earlier behaviour): nothing in the
// startup window (billing starts before its neighbour listens), a warning past it, an error after one success.
export function grantLog(served: boolean, sinceStartMs: number): "none" | "warn" | "error" {
  if (served) return "error";
  return sinceStartMs < grantsWindowMs ? "none" : "warn";
}
export function grantVerdict(served: boolean, sinceStartMs: number, notReady: boolean): "wait" | "fail" {
  return !served && notReady && sinceStartMs < grantsWindowMs ? "wait" : "fail";
}

/** The grants loop: `attempt` until the first success, then (with `repeat`, flags) every minute. A failed attempt
 * is tried again after a wait that doubles to a minute, and the process never exits over it. With the strict flag
 * on, /billing/health says 503 while a failure lasts and the rest of the billing path keeps serving. */
export async function grantsLoop(
  billing: { attempt(sinceStartMs: number, retryInS?: number): Promise<boolean> },
  o: { repeat: boolean; sleep?: (ms: number) => Promise<void>; now?: () => number },
): Promise<void> {
  const sleep = o.sleep ?? ((ms: number) => new Promise<void>((r) => setTimeout(r, ms))), now = o.now ?? Date.now;
  const started = now();
  for (let wait = 1;;) {
    if (await billing.attempt(now() - started, Math.min(wait * 2, 60))) {
      if (!o.repeat) return;
      wait = 60;
    } else wait = Math.min(wait * 2, 60);
    await sleep(wait * 1000);
  }
}

export function service(s: Settings) {
  const fetcher = s.fetcher ?? fetch;
  const origin = s.origin.replace(/\/$/, "");
  const issuer = s.broker.replace(/\/$/, "");
  const brokerAt = (s.brokerInternal || s.broker).replace(/\/$/, "");
  const crud = s.crud.replace(/\/$/, "");
  const keys = brokerKeys(brokerAt, fetcher);
  const doc = JSON.parse(s.document) as { plans: Record<string, unknown>; trial?: { plans: string[] } };
  const plans = Object.keys(doc.plans);

  // One flag as flagd evaluates it now, for `account` where it is per account. Asked directly (a
  // flagd's origin, or `mesh`), flagd is told the account and the host the app is reached at in the
  // headers it reads them from (flags_plugin.cue's --context-from-header), as the door tells it; asked
  // through the door, the door says both, the account from the session `auth` carries.
  const flagsAt = !s.flags ? "" : s.flags === "origin" ? origin : s.flags === "mesh" ? "http://localhost:3500" : s.flags.replace(/\/$/, "");
  const host = new URL(origin).hostname;
  function ofrep(key: string, account?: string, auth?: string | null, timeoutMs = 10_000): Promise<Response> {
    const headers: Record<string, string> = { "content-type": "application/json" };
    if (s.flags === "mesh") headers["dapr-app-id"] = "flagd";
    if (s.flags !== "origin") {
      headers["x-pronto-host"] = host;
      if (account) headers["x-pronto-account"] = account;
    } else if (auth) headers.authorization = auth;
    return fetcher(`${flagsAt}/ofrep/v1/evaluate/flags/${encodeURIComponent(key)}`, {
      method: "POST", headers, body: JSON.stringify({ context: account ? { targetingKey: account } : {} }), signal: AbortSignal.timeout(timeoutMs),
    });
  }

  async function rpc(fn: string, auth: string, args: Record<string, unknown> = {}, deadline = false): Promise<Response> {
    return await fetcher(`${crud}/rpc/${fn}`, {
      method: "POST", headers: { authorization: auth, "content-type": "application/json" }, body: JSON.stringify(args),
      // Strict only: a grants write that hangs must fail (a TimeoutError is no NotReady, so a "fail" verdict), never keep health at 200 and stall the loop.
      ...(deadline ? { signal: AbortSignal.timeout(30_000) } : {}),
    });
  }
  const asService = (fn: string, args: Record<string, unknown>, deadline = false) => rpc(fn, `Bearer ${s.serviceJwt}`, args, deadline);

  // Who asks, as the gateway reads the reader's own session: an account, never a guest.
  async function reader(req: Request): Promise<string | Response> {
    const auth = req.headers.get("authorization");
    if (!auth?.startsWith("Bearer ")) return json(401, { error: "sign in" });
    const res = await rpc("billing_me", auth);
    if (!res.ok) {
      await res.body?.cancel();
      return json(401, { error: "sign in" });
    }
    const me = await res.json() as { account: string | null; guest: boolean };
    if (!me.account) return json(401, { error: "sign in" });
    if (me.guest) return json(403, { error: "save your games first" });
    return me.account;
  }

  // The author's grants, handed over whole: written, moved, or taken away. With
  // flags, the set is the flag billing_grants as flagd serves it now; without,
  // the one the release carried. A set already handed over is not sent again.
  let granted: string | null = null;
  async function grant(strict = false): Promise<void> {
    if (!strict) {
      // The earlier behaviour: any failure is the loop's to log and retry.
      const set = s.flags ? await flagged() : s.grants ?? "[]";
      if (set === granted) return;
      const res = await asService("billing_grant", { grants: JSON.parse(set) });
      if (!res.ok) throw new Error(`billing_grant answered ${res.status}: ${brief(await res.text())}`);
      await res.body?.cancel();
      granted = set;
      return;
    }
    const up = <T>(p: Promise<T>) => p.catch((e) => { throw refused(e) ? new NotReady(e.message) : e; });
    const set = s.flags ? await up(flagged()) : s.grants ?? "[]";
    if (set === granted) return;
    // A changed write that times out may still have committed: what is held is unknown until a write is
    // confirmed, so a flag going back to the old set writes again.
    granted = null;
    const res = await up(asService("billing_grant", { grants: JSON.parse(set) }, true));
    if (!res.ok) {
      const text = await res.text();
      const why = `billing_grant answered ${res.status}: ${brief(text)}`;
      throw res.status === 503 || (res.status === 404 && text.includes("PGRST202")) ? new NotReady(why) : new Error(why);
    }
    await res.body?.cancel();
    granted = set;
  }
  // The flag as OFREP evaluates it: a string holding the grants' JSON array. Any
  // other answer is an error, so a flagd that is down or a flag gone takes no grant away.
  async function flagged(): Promise<string> {
    const res = await ofrep("billing_grants");
    if (!res.ok) throw new Error(`flag billing_grants answered ${res.status}: ${brief(await res.text())}`);
    const { value } = await res.json() as { value?: unknown };
    if (typeof value !== "string" || !Array.isArray(JSON.parse(value))) throw new Error("flag billing_grants holds no list of grants");
    return value;
  }

  async function entitle(token: string): Promise<Response> {
    let e;
    try {
      e = await verifyEntitlement(token, { issuer, tenant: origin, keys });
    } catch (err) {
      if (err instanceof Refused) return json(400, { error: err.message });
      throw err;
    }
    const res = await asService("billing_entitle", {
      account: e.account, plan: e.plan, active: e.active, through: new Date(e.through * 1000).toISOString(), manage: e.manage, ver: e.ver,
    });
    if (!res.ok) throw new Error(`billing_entitle answered ${res.status}: ${brief(await res.text())}`);
    await res.body?.cancel();
    if (e.trial) {
      // Failing throws, so the broker is not answered and Stripe sends it again.
      const t = await asService("billing_trial_state", {
        account: e.account, state: e.trial.state, plan: e.plan, amount: e.trial.amount, currency: e.trial.currency,
        charges_at: new Date(e.trial.chargesAt * 1000).toISOString(), ver: e.ver,
      });
      if (!t.ok) throw new Error(`billing_trial_state answered ${t.status}: ${brief(await t.text())}`);
      await t.body?.cancel();
    }
    return new Response(null, { status: 204 });
  }

  // The free trial is off unless the document has one and its flag, if any, is true for this account as flagd
  // evaluates it now. A flag that cannot be asked is off, never on. The broker's consent check carries no
  // session, so a flag that names accounts needs flagd asked directly.
  //
  // While the strict flag is on (`strict`), a flag that cannot be asked (no flagd, flagd down or erroring, the
  // flag not there, an answer that is no boolean) fails the request instead, never mistaken for a trial turned
  // off. Otherwise it is the earlier behaviour, exactly: off.
  async function trialOn(account: string, strict: boolean): Promise<boolean> {
    if (!doc.trial) return false;
    if (!s.trialFlag) return true;
    if (!strict) {
      if (!s.flags) return false;
      try {
        const res = await ofrep(s.trialFlag, account);
        if (!res.ok) {
          await res.body?.cancel();
          return false;
        }
        return (await res.json() as { value?: unknown }).value === true;
      } catch {
        return false;
      }
    }
    if (!s.flags) throw new Error("BILLING_TRIAL_FLAG needs BILLING_FLAGS: where to ask it");
    const res = await ofrep(s.trialFlag, account);
    const answer = res.ok ? await res.json() as { value?: unknown } : (await res.body?.cancel(), null);
    if (!res.ok || typeof answer?.value !== "boolean") throw new Error(`flag ${s.trialFlag}: flagd answered ${res.status}`);
    return answer.value;
  }

  // What the strict flag says now (for `account`, with the reader's `auth`, where there is one): true, false, or
  // undefined when it cannot say (a lookup that fails, an answer that is no boolean). No flag configured, or no
  // flagd to ask: false. Callers that only act on a true use `strictOn`.
  async function strictAnswer(account?: string, auth?: string | null): Promise<boolean | undefined> {
    if (!s.strictFlag || !s.flags) return false;
    try {
      const res = await ofrep(s.strictFlag, account, auth);
      if (!res.ok) {
        await res.body?.cancel();
        return undefined;
      }
      const { value } = await res.json() as { value?: unknown };
      return typeof value === "boolean" ? value : undefined;
    } catch {
      return undefined;
    }
  }
  // Where the strict path needs an answer: a configured strict flag that cannot be asked fails the request, never
  // quietly reads as off. (The grants health keeps the last mode instead: see `attempt`.)
  const strictOn = async (account?: string, auth?: string | null): Promise<boolean> => {
    const answer = await strictAnswer(account, auth);
    if (answer === undefined) throw new Error(`flag ${s.strictFlag}: cannot be asked`);
    return answer;
  };

  // Whether the reader's calls to Stripe go through the airlock's door, as flagd evaluates the flag for them now:
  // through the door, with the reader's own session, which its OFREP route reads the account from; asked
  // directly, for the reader's account. Unset flag: no word, the broker's own way.
  //
  // Only a lookup that succeeds with true uses the door. A deploy never changes behaviour, only a flag does, and the
  // released path is direct: with stripe_door off, a flagd outage must not break a paid checkout. So a lookup that
  // fails (the fetch throws, flagd answers 5xx or 4xx, an answer that is no boolean, a body that is not JSON), or
  // does not answer within rules.cue's doorLookupTimeoutMs, takes the direct route (false) and logs one warning
  // carrying billing_alert=stripe_door_lookup_failed, the line an alert rule counts. `failOpen` false (the route
  // probe, a diagnostic and no payment path) throws instead, for the usual 502.
  async function doorOn(account: string | undefined, auth: string | null, failOpen = true): Promise<boolean | undefined> {
    if (!s.doorFlag) return undefined;
    if (!s.flags) throw new Error("BILLING_DOOR_FLAG needs BILLING_FLAGS: where to ask it");
    try {
      const res = await ofrep(s.doorFlag, account, auth, RULES.doorLookupTimeoutMs);
      const answer = res.ok ? await res.json() as { value?: unknown } : (await res.body?.cancel(), null);
      if (!res.ok || typeof answer?.value !== "boolean") throw new Error(`flag ${s.doorFlag}: flagd answered ${res.status}`);
      return answer.value;
    } catch (e) {
      if (!failOpen) throw e;
      console.warn(`billing: warn: billing_alert=stripe_door_lookup_failed stripe_door lookup failed, taking the direct route: ${(e as Error).message}`);
      return false;
    }
  }

  async function trialStatus(account: string): Promise<{ state: string | null; holds: boolean } & Record<string, unknown>> {
    const res = await asService("billing_trial_status", { account });
    if (!res.ok) throw new Error(`billing_trial_status answered ${res.status}: ${brief(await res.text())}`);
    return await res.json();
  }

  // A ticket for the broker to ask this service about: what the account consented to, or nothing
  // for an offer. Refused by the database for an account whose trial is spent.
  async function trialTicket(account: string, c: Record<string, unknown> = {}): Promise<string> {
    const res = await asService("billing_trial_ask", {
      account, plan: c.plan ?? null, amount: c.amount ?? null, currency: c.currency ?? null, charges_at: c.charges_at ?? null, terms: c.terms ?? null,
    });
    if (!res.ok) throw new Error(`billing_trial_ask answered ${res.status}: ${brief(await res.text())}`);
    return await res.json();
  }

  async function trial(req: Request, path: string): Promise<Response> {
    if (path === "/billing/trial/consent") {
      // The broker's: the ticket is the proof, so there is no reader.
      const a = await args(req);
      if (typeof a.account !== "string" || typeof a.ticket !== "string" || !(await trialOn(a.account, await strictOn(a.account, null)))) return json(404, { error: "not found" });
      const res = await asService("billing_trial_take", { account: a.account, ticket: a.ticket });
      if (!res.ok) throw new Error(`billing_trial_take answered ${res.status}: ${brief(await res.text())}`);
      const consent = await res.json();
      return consent ? json(200, consent) : json(404, { error: "not found" });
    }
    const account = await reader(req);
    if (account instanceof Response) return account;
    // The door lookup comes first, and fails open: a lookup that fails takes the direct route and the ticket check
    // goes on as it would with the flag off. Its answer (undefined when no door flag is configured) goes on to the
    // broker as it is.
    const door = { door: await doorOn(account, req.headers.get("authorization")) };
    const strict = await strictOn(account, req.headers.get("authorization"));
    if (!(await trialOn(account, strict))) return json(404, { error: "not found" });
    const a = await args(req, 8192);
    const held = await trialStatus(account);
    if (path === "/billing/trial") {
      const none = { ...held, eligible: false, offers: [] };
      if (held.holds || held.state) return json(200, none);
      const res = await toBroker("/trial/offer", { account, ticket: await trialTicket(account), currency: a.currency }, req.headers.get("authorization"), door);
      // With the strict flag on, a broker that does not know trials (404) fails the request as any refusal does:
      // a trial's flag is turned on only where the broker offers trials, so this is no account's ineligibility.
      // Otherwise, as before, such a broker offers none.
      if (res.status === 404 && !strict) return json(200, none);
      return res.ok ? json(200, { ...held, ...(await res.json()) }) : res;
    }
    if (a.consent !== true) return json(400, { error: "consent is required" });
    const plan = typeof a.plan === "string" && doc.trial!.plans.includes(a.plan) ? a.plan : null;
    if (!plan || !Number.isInteger(a.amount) || typeof a.currency !== "string" || typeof a.charges_at !== "string" || Number.isNaN(Date.parse(a.charges_at))) {
      return json(400, { error: "plan, amount, currency and charges_at required" });
    }
    if (typeof a.terms !== "string" || a.terms.trim() === "" || a.terms.length > 1000) return json(400, { error: "terms required, at most 1000 characters" });
    if (held.holds || held.state) return json(409, { error: held.holds ? "holds" : "used" });
    const ticket = await trialTicket(account, { plan, amount: a.amount, currency: a.currency, charges_at: a.charges_at, terms: a.terms });
    return await toBroker("/trial/checkout", { account, ticket, locale: a.locale, return: a.return }, req.headers.get("authorization"), door);
  }

  // `auth`: the reader's session, for a call made on the reader's behalf, which then says which way
  // its Stripe calls go (doorOn); a call with none (the broker's own consent check) says nothing.
  async function toBroker(path: string, args: Record<string, unknown>, auth?: string | null, known?: { door: boolean | undefined }): Promise<Response> {
    const door = known ? known.door : auth !== undefined && typeof args.account === "string" ? await doorOn(args.account, auth) : undefined;
    const res = await fetcher(`${brokerAt}${path}`, {
      method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ tenant: origin, ...args, ...(door === undefined ? {} : { door }) }),
      signal: AbortSignal.timeout(20_000),
    });
    return json(res.status, await res.json());
  }

  async function manageOf(account: string): Promise<string | null> {
    const res = await asService("billing_manage", { account });
    if (!res.ok) throw new Error(`billing_manage answered ${res.status}`);
    return await res.json();
  }

  async function args(req: Request, max = 4096): Promise<Record<string, unknown>> {
    const text = await readCapped(req.body, max, req.headers.get("content-length"));
    try {
      const v = JSON.parse(text || "{}");
      return typeof v === "object" && v !== null ? v : {};
    } catch {
      return {};
    }
  }

  // The route probe's own meter, ahead of any lookup: calls a minute for each client and for all of them, in this process.
  const routeSeen = new Map<string, { n: number; at: number }>();
  function routeTaken(client: string): boolean {
    const t = Date.now();
    const take = (key: string, per: number): boolean => {
      let held = routeSeen.get(key);
      if (!held || t - held.at >= RULES.routeLimits.windowMs) held = { n: 0, at: t };
      routeSeen.delete(key);
      routeSeen.set(key, held);
      if (routeSeen.size > 10_000) routeSeen.delete(routeSeen.keys().next().value!);
      return ++held.n <= per;
    };
    return take(`client ${client}`, RULES.routeLimits.perClient) && take("all", RULES.routeLimits.global);
  }

  const handler = async function handler(req: Request): Promise<Response> {
    const path = new URL(req.url).pathname;
    try {
      if (req.method === "GET" && path === "/.well-known/pronto-billing.json") {
        return new Response(s.document, { headers: { "content-type": "application/json", "cache-control": "max-age=300" } });
      }
      if (req.method === "POST" && path === "/billing/events") {
        const token = await readCapped(req.body, 8192, req.headers.get("content-length"));
        return token === null ? json(413, { error: "too large" }) : await entitle(token);
      }
      if (req.method === "POST" && (path === "/billing/trial" || path === "/billing/trial/checkout" || path === "/billing/trial/consent")) {
        return await trial(req, path);
      }
      if (req.method === "POST" && (path === "/billing/checkout" || path === "/billing/portal" || path === "/billing/resync")) {
        const account = await reader(req);
        if (account instanceof Response) return account;
        const a = await args(req);
        const plan = typeof a.plan === "string" && plans.includes(a.plan) ? a.plan : plans[0];
        if (path === "/billing/checkout") {
          return await toBroker("/checkout", { account, plan, currency: a.currency, locale: a.locale, return: a.return }, req.headers.get("authorization"));
        }
        const manage = await manageOf(account);
        if (!manage) return json(404, { error: "no subscription" });
        if (path === "/billing/portal") return await toBroker("/portal", { account, manage, return: a.return }, req.headers.get("authorization"));
        // What the broker holds now, for a page that waited on a push.
        const res = await toBroker("/resync", { account, manage, plan }, req.headers.get("authorization"));
        if (!res.ok) return res;
        return await entitle((await res.json()).token);
      }
      if (req.method === "GET" && path === "/billing/health") {
        return grantsError === null ? json(200, { ok: true }) : json(503, { error: "grants not written" });
      }
      // The reader's own account read at Stripe through the broker, nothing written: what a flag's live
      // check asks as the tester (PRONTO-218).
      // Which way the broker would send a call to Stripe for the door flag as evaluated for no one: anonymous, no
      // account, nothing read or written, and no call to Stripe (the broker's /route runs its real route selection
      // and stops there). A production scenario asserts {door: true, transport: "door"} once the flag is on.
      if (req.method === "GET" && path === "/billing/route") {
        // Off until its flag: absent (404) unless the door flag is configured and evaluates true for no one.
        if (!s.doorFlag) return json(404, { error: "not found" });
        // The limiter comes first: an anonymous probe is metered before it reaches flagd or the broker.
        if (!routeTaken(req.headers.get("x-forwarded-for")?.split(",").at(-1)?.trim() || "")) return json(429, { error: "too many requests; try again in a minute" });
        // A diagnostic, no payment path: a lookup that fails is the usual 502, before the broker is asked.
        const door = await doorOn(undefined, null, false);
        if (door !== true) return json(404, { error: "not found" });
        const res = await toBroker("/route", {}, null, { door });
        if (!res.ok) return res;
        const { transport } = await res.json() as { transport?: unknown };
        return json(200, { ok: true, door: door ?? null, transport: transport ?? null });
      }
      if (req.method === "GET" && path === "/billing/probe") {
        const account = await reader(req);
        if (account instanceof Response) return account;
        return await toBroker("/probe", { account }, req.headers.get("authorization"));
      }
      return json(404, { error: "not found" });
    } catch (e) {
      console.error(`billing: ${(e as Error).message}`);
      return json(502, { error: "billing unavailable" });
    }
  };
  // One try at the grants, as the loop makes it: a success clears the error /billing/health reports, a
  // failure no wait can mend sets it, so a revoked grant never stays effective on a healthy-looking
  // deployment. The loop retries either way, so a corrected flag push recovers with no deploy.
  let grantsError: string | null = null, served = false, waiting = false, lastStrict: boolean | undefined;
  // False when the grants were not written. With the strict flag on: a "wait" (a neighbour not up yet, inside the
  // startup window) is quiet, a "fail" is logged and turns /billing/health 503, and neither stops the loop
  // (grantsLoop). Otherwise the earlier behaviour: the failure is logged by grantLog and health stays as it was.
  async function attempt(sinceStartMs: number, retryInS = 0): Promise<boolean> {
    // A flagd that cannot say keeps the mode the last answer gave: a failed flag read is not a way out of the strict
    // mode, and so never clears the error it holds. Only a flag that answers false leaves it.
    const answer = await strictAnswer();
    // With no answer yet to keep, a configured strict flag counts as on: a failed first lookup never leaves a failed
    // grants write healthy. Unset, it is the earlier behaviour.
    const strict = answer ?? lastStrict ?? Boolean(s.strictFlag);
    if (answer !== undefined) lastStrict = answer;
    if (answer === false) grantsError = null;
    try {
      await grant(strict);
      served = true;
      waiting = false;
      grantsError = null;
      return true;
    } catch (e) {
      if (!strict) {
        const log = grantLog(served, sinceStartMs);
        if (log === "error") console.error(`billing: grants not written: ${(e as Error).message}`);
        else if (log === "warn") console.warn(`billing: grants not written yet, retrying in ${retryInS} s: ${(e as Error).message}`);
        return false;
      }
      const notReady = e instanceof NotReady;
      if (grantVerdict(served, sinceStartMs, notReady) === "fail") {
        grantsError = (e as Error).message;
        // The word "error" is what the log shipper reads a line's level by: without it this line is counted as info and no alert sees it.
        console.error(`billing: error: grants not written (a revoked grant may still be honoured): ${grantsError}`);
      } else if (!waiting) {
        console.log(`billing: waiting for the gateway to write the grants, retrying until ${grantsWindowMs / 1000} s after start: ${(e as Error).message}`);
      }
      waiting = notReady;
      return false;
    }
  }
  return Object.assign(handler, { grant, attempt });
}

if (import.meta.main) {
  const env = (k: string) => {
    const v = Deno.env.get(k);
    if (!v) throw new Error(`${k} is required`);
    return v;
  };
  const billing = service({
    origin: env("ORIGIN"), broker: env("BILLING_BROKER"), brokerInternal: Deno.env.get("BILLING_BROKER_INTERNAL"),
    crud: env("CRUD_URL"), serviceJwt: env("SERVICE_JWT"), document: env("BILLING_DOCUMENT"), grants: Deno.env.get("BILLING_GRANTS"),
    flags: Deno.env.get("BILLING_FLAGS") || undefined, trialFlag: Deno.env.get("BILLING_TRIAL_FLAG") || undefined,
    doorFlag: Deno.env.get("BILLING_DOOR_FLAG") || undefined, strictFlag: Deno.env.get("BILLING_STRICT_FLAG") || undefined,
  });
  Deno.serve({ port: Number(Deno.env.get("BILLING_PORT") ?? 8688) }, billing);
  // Until the gateway serves billing_grant, as it does once it has reloaded its schema; with
  // flags, every minute after, so a push reaches the database with no deploy. A failure is retried with
  // backoff and reported on /billing/health; it never exits the process.
  await grantsLoop(billing, { repeat: !!Deno.env.get("BILLING_FLAGS") });
}
