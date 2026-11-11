// The service hands the author's grants to the database: the release's set, or
// the flag billing_grants as flagd serves it now; each set once, and none taken
// away because flagd could not be asked.
import { grantLog, service } from "./service.ts";
import { entitlementClaims } from "./broker/core.ts";
import { signEs256 } from "./shared.ts";

const eq = (a: unknown, b: unknown, m = "") => { if (JSON.stringify(a) !== JSON.stringify(b)) throw new Error(`${m}: expected ${JSON.stringify(b)}, got ${JSON.stringify(a)}`); };
const ANA = [{ account: "00000000-0000-4000-8000-00000000000a", plan: "analysis", through: "2028-10-28T23:59:59Z" }];

function stage(flag: () => Response) {
  const handed: unknown[] = [];
  const fetcher = ((input: string | URL | Request, init?: RequestInit) => {
    const url = String(input);
    if (url === "http://crud/rpc/billing_grant") {
      handed.push(JSON.parse(String(init?.body)).grants);
      return Promise.resolve(new Response(null, { status: 204 }));
    }
    if (url === "http://flagd:8693/ofrep/v1/evaluate/flags/billing_grants" || url === "https://a.example/ofrep/v1/evaluate/flags/billing_grants") return Promise.resolve(flag());
    return Promise.resolve(new Response("", { status: 404 }));
  }) as typeof fetch;
  const base = { origin: "https://a.example", broker: "https://b.example", crud: "http://crud", serviceJwt: "t", document: JSON.stringify({ owner: "o", plans: { analysis: {} } }), fetcher };
  return { handed, base };
}

Deno.test("without flags, the release's grants, once", async () => {
  const { handed, base } = stage(() => new Response("", { status: 500 }));
  const s = service({ ...base, grants: JSON.stringify(ANA) });
  await s.grant();
  await s.grant();
  eq(handed, [ANA], "handed over once");
});

Deno.test("with flags, the flag as flagd serves it, each set once", async () => {
  let value = JSON.stringify(ANA);
  const { handed, base } = stage(() => Response.json({ key: "billing_grants", value, variant: "default" }));
  const s = service({ ...base, grants: "[]", flags: "http://flagd:8693" });
  await s.grant();
  await s.grant();
  value = "[]";
  await s.grant();
  eq(handed, [ANA, []], "the flag's set, then the push that took it away");
});

Deno.test("a flagd that cannot be asked takes no grant away", async () => {
  let answer = () => Response.json({ value: JSON.stringify(ANA) });
  const { handed, base } = stage(() => answer());
  const s = service({ ...base, flags: "http://flagd:8693" });
  await s.grant();
  for (const down of [() => new Response("", { status: 503 }), () => Response.json({ errorCode: "FLAG_NOT_FOUND" }), () => Response.json({ value: "{}" })]) {
    answer = down;
    eq(await s.grant().then(() => "handed", () => "refused"), "refused", "an answer that is no list");
  }
  eq(handed, [ANA], "nothing handed over after the first");
});

Deno.test("in a release, the flag through the app's own door", async () => {
  const { handed, base } = stage(() => Response.json({ value: JSON.stringify(ANA) }));
  await service({ ...base, flags: "origin" }).grant();
  eq(handed, [ANA], "read at https://a.example/ofrep/");
});

// The free trial: what the service answers and asks of the database and the broker, with the
// flag, the account's status and the broker as each test sets them.
const ANA_ID = "00000000-0000-4000-8000-00000000000a";
function trialStage(o: { flag?: () => Response; status?: Record<string, unknown>; offer?: () => Response; checkout?: () => Response; document?: unknown; consent?: unknown; door?: () => Response } = {}) {
  const calls: { fn: string; args: Record<string, unknown> }[] = [];
  const broker: { path: string; body: Record<string, unknown> }[] = [];
  const flagBodies: unknown[] = [];
  const doorAsks: { auth: string | null; body: unknown }[] = [];
  const status = { state: null, plan: null, amount: null, currency: null, charges_at: null, holds: false, ...o.status };
  const fetcher = ((input: string | URL | Request, init?: RequestInit) => {
    const url = String(input);
    const body = init?.body ? JSON.parse(String(init.body)) : {};
    if (url.startsWith("http://crud/rpc/")) {
      const fn = url.slice("http://crud/rpc/".length);
      calls.push({ fn, args: body });
      if (fn === "billing_me") return Promise.resolve(Response.json({ account: ANA_ID, guest: false }));
      if (fn === "billing_trial_status") return Promise.resolve(Response.json(status));
      if (fn === "billing_trial_ask") return Promise.resolve(Response.json("t".repeat(32)));
      if (fn === "billing_trial_take") return Promise.resolve(Response.json(o.consent ?? null));
      return Promise.resolve(new Response(null, { status: 204 }));
    }
    if (url === "http://flagd:8693/ofrep/v1/evaluate/flags/free_trial") {
      flagBodies.push(body);
      return Promise.resolve(o.flag ? o.flag() : Response.json({ value: true }));
    }
    if (url === "http://flagd:8693/ofrep/v1/evaluate/flags/stripe_door") {
      doorAsks.push({ auth: new Headers(init?.headers).get("authorization"), body });
      return Promise.resolve(o.door ? o.door() : Response.json({ value: true }));
    }
    if (url.startsWith("https://b.example/trial/")) {
      broker.push({ path: url.slice("https://b.example".length), body });
      if (url.endsWith("/offer")) return Promise.resolve(o.offer ? o.offer() : Response.json({ eligible: true, offers: [{ plan: "analysis", amount: 1990 }] }));
      return Promise.resolve(o.checkout ? o.checkout() : Response.json({ url: "https://checkout.example/c" }));
    }
    return Promise.resolve(new Response("", { status: 404 }));
  }) as typeof fetch;
  const doc = o.document === undefined ? { owner: "o", plans: { analysis: {} }, trial: { months: 3, plans: ["analysis"], remindDays: 7 } } : o.document;
  const make = (extra: Record<string, unknown> = {}) => service({
    origin: "https://a.example", broker: "https://b.example", crud: "http://crud", serviceJwt: "t", document: JSON.stringify(doc), fetcher,
    flags: "http://flagd:8693", trialFlag: "free_trial", ...extra,
  });
  const ask = (svc: ReturnType<typeof make>, path: string, body: unknown = {}) =>
    svc(new Request(`https://a.example${path}`, { method: "POST", headers: { authorization: "Bearer reader", "content-type": "application/json" }, body: JSON.stringify(body) }));
  return { calls, broker, flagBodies, doorAsks, make, ask };
}
const fns = (calls: { fn: string }[]) => calls.map((c) => c.fn);
const CONSENT = { plan: "analysis", amount: 1990, currency: "brl", charges_at: "2027-02-05T12:00:00Z", terms: "Free until Feb 5, then R$ 19,90 a month.", consent: true, locale: "pt-BR", return: "/?premium=trial" };

Deno.test("the trial is off when its flag is off, down, or erroring: 404, and nothing asked of the broker", async () => {
  const downs: [string, () => Response][] = [
    ["false", () => Response.json({ value: false })],
    ["not a boolean", () => Response.json({ value: "true" })],
    ["flag not found", () => Response.json({ errorCode: "FLAG_NOT_FOUND" }, { status: 404 })],
    ["flagd down", () => new Response("", { status: 503 })],
    ["flagd unreachable", () => { throw new TypeError("connection refused"); }],
  ];
  for (const [why, flag] of downs) {
    const t = trialStage({ flag });
    for (const [path, body] of [["/billing/trial", {}], ["/billing/trial/checkout", CONSENT], ["/billing/trial/consent", { account: ANA_ID, ticket: "t".repeat(32) }]] as const) {
      const res = await t.ask(t.make(), path, body);
      eq([why, path, res.status], [why, path, 404], "off");
      await res.body?.cancel();
    }
    eq(t.broker, [], `${why}: no broker call`);
    eq(fns(t.calls).filter((f) => f.startsWith("billing_trial")), [], `${why}: no trial function called`);
  }
  // A flag configured with nowhere to ask it, and a document that has no trial, are off too.
  const noFlagd = trialStage();
  eq((await noFlagd.ask(noFlagd.make({ flags: undefined }), "/billing/trial")).status, 404, "no flagd to ask");
  const noTrial = trialStage({ document: { owner: "o", plans: { analysis: {} } } });
  eq((await noTrial.ask(noTrial.make({ trialFlag: undefined }), "/billing/trial")).status, 404, "no trial in the document");
});

Deno.test("the trial is on for the account the flag says so for, and with no flag configured, wherever the document has one", async () => {
  const flagged = trialStage();
  const res = await flagged.ask(flagged.make(), "/billing/trial");
  eq(res.status, 200, "on");
  await res.body?.cancel();
  eq(flagged.flagBodies, [{ context: { targetingKey: ANA_ID } }], "the flag is asked for this account");
  const open = trialStage({ flag: () => new Response("", { status: 500 }) });
  eq((await open.ask(open.make({ trialFlag: undefined, flags: undefined }), "/billing/trial")).status, 200, "no flag configured");
  eq(open.flagBodies, [], "none asked");
});

Deno.test("an eligible account is offered what the broker offers, through a ticket for an offer", async () => {
  const t = trialStage();
  const res = await t.ask(t.make(), "/billing/trial", { currency: "brl" });
  eq(await res.json(), { state: null, plan: null, amount: null, currency: null, charges_at: null, holds: false, eligible: true, offers: [{ plan: "analysis", amount: 1990 }] }, "status and offers");
  eq(t.calls.filter((c) => c.fn === "billing_trial_ask").map((c) => c.args), [{ account: ANA_ID, plan: null, amount: null, currency: null, charges_at: null, terms: null }], "an offer's ticket holds no consent");
  eq(t.broker, [{ path: "/trial/offer", body: { tenant: "https://a.example", account: ANA_ID, ticket: "t".repeat(32), currency: "brl" } }]);
});

Deno.test("an account that holds a plan or has a trial is offered none, and the broker is not asked", async () => {
  for (const status of [{ holds: true }, { state: "running", plan: "analysis", amount: 1990, currency: "brl", charges_at: "2027-02-05T12:00:00Z" }, { state: "failed" }]) {
    const t = trialStage({ status });
    const res = await t.ask(t.make(), "/billing/trial");
    const out = await res.json();
    eq([res.status, out.eligible, out.offers, out.holds, out.state], [200, false, [], status.holds ?? false, status.state ?? null], JSON.stringify(status));
    eq(t.broker, [], "no broker call");
    eq(fns(t.calls).includes("billing_trial_ask"), false, "no ticket");
  }
  // An old broker has no /trial/offer: no offer, and not an error.
  const old = trialStage({ offer: () => Response.json({ error: "not found" }, { status: 404 }) });
  const out = await (await old.ask(old.make(), "/billing/trial")).json();
  eq([out.eligible, out.offers], [false, []], "an old broker offers none");
});

Deno.test("a trial starts only on a consent that is true, and says what it consented to", async () => {
  const bad = async (body: Record<string, unknown>) => {
    const t = trialStage();
    const res = await t.ask(t.make(), "/billing/trial/checkout", { ...CONSENT, ...body });
    await res.body?.cancel();
    eq(fns(t.calls).includes("billing_trial_ask") || t.broker.length > 0, false, `nothing asked for ${JSON.stringify(body).slice(0, 40)}`);
    return res.status;
  };
  eq(await bad({ consent: undefined }), 400, "no consent");
  eq(await bad({ consent: false }), 400);
  eq(await bad({ consent: "true" }), 400, "a string is not a yes");
  eq(await bad({ consent: 1 }), 400);
  eq(await bad({ terms: "" }), 400, "no terms");
  eq(await bad({ terms: "   " }), 400);
  eq(await bad({ terms: "x".repeat(1001) }), 400, "terms over 1000 characters");
  eq(await bad({ plan: "coach" }), 400, "a plan not on trial");
  eq(await bad({ amount: "19.90" }), 400);
  eq(await bad({ charges_at: "someday" }), 400);
  const t = trialStage();
  const res = await t.ask(t.make(), "/billing/trial/checkout", { ...CONSENT, terms: "x".repeat(1000) });
  eq([res.status, (await res.json()).url], [200, "https://checkout.example/c"]);
  eq(t.calls.find((c) => c.fn === "billing_trial_ask")!.args, {
    account: ANA_ID, plan: "analysis", amount: 1990, currency: "brl", charges_at: "2027-02-05T12:00:00Z", terms: "x".repeat(1000),
  }, "the consent as the page showed it");
  eq(t.broker, [{ path: "/trial/checkout", body: { tenant: "https://a.example", account: ANA_ID, ticket: "t".repeat(32), locale: "pt-BR", return: "/?premium=trial" } }]);
});

Deno.test("a trial is refused to an account that holds a plan or has had one", async () => {
  for (const [status, why] of [[{ holds: true }, "holds"], [{ state: "converted" }, "used"], [{ state: "running" }, "used"]] as const) {
    const t = trialStage({ status });
    const res = await t.ask(t.make(), "/billing/trial/checkout", CONSENT);
    eq([res.status, (await res.json()).error], [409, why]);
    eq(t.broker, [], "the broker is not asked");
    eq(fns(t.calls).includes("billing_trial_ask"), false, "no ticket");
  }
});

Deno.test("what the broker refuses a trial for, the page hears as it is", async () => {
  for (const [status, error] of [[409, "stale"], [409, "used"], [403, "ticket refused"]] as const) {
    const t = trialStage({ checkout: () => Response.json({ error }, { status }) });
    const res = await t.ask(t.make(), "/billing/trial/checkout", CONSENT);
    eq([res.status, (await res.json()).error], [status, error]);
  }
});

Deno.test("only a ticket the broker holds is given back, once, and with no reader", async () => {
  const t = trialStage({ consent: { plan: "analysis", amount: 1990, currency: "brl", charges_at: "2027-02-05T12:00:00+00:00", terms: "t" } });
  const res = await t.make()(new Request("https://a.example/billing/trial/consent", { method: "POST", body: JSON.stringify({ account: ANA_ID, ticket: "t".repeat(32) }) }));
  eq([res.status, (await res.json()).plan], [200, "analysis"], "no Authorization needed: the ticket is the proof");
  eq(t.calls.map((c) => c.fn), ["billing_trial_take"]);
  const none = trialStage();
  const gone = await none.make()(new Request("https://a.example/billing/trial/consent", { method: "POST", body: JSON.stringify({ account: ANA_ID, ticket: "t".repeat(32) }) }));
  eq(gone.status, 404, "an unknown or spent ticket");
  const malformed = await none.make()(new Request("https://a.example/billing/trial/consent", { method: "POST", body: JSON.stringify({ account: 7 }) }));
  eq(malformed.status, 404);
});

// An entitlement as the broker signs it, checked against the key this test serves.
async function signed(claims: Record<string, unknown>) {
  const pair = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]);
  const jwk = { ...(await crypto.subtle.exportKey("jwk", pair.publicKey)), kid: "k1" };
  const now = Math.floor(Date.now() / 1000);
  const base = entitlementClaims({ issuer: "https://b.example", tenant: "https://a.example", account: ANA_ID, plan: "analysis", active: true, through: now + 9999, manage: "m", ver: 5, now });
  return { token: await signEs256(pair.privateKey, "k1", { ...base, ...claims }), jwk };
}
async function pushed(claims: Record<string, unknown>) {
  const { token, jwk } = await signed(claims);
  const calls: { fn: string; args: Record<string, unknown> }[] = [];
  const fetcher = ((input: string | URL | Request, init?: RequestInit) => {
    const url = String(input);
    if (url === "https://b.example/jwks") return Promise.resolve(Response.json({ keys: [jwk] }));
    calls.push({ fn: url.slice("http://crud/rpc/".length), args: JSON.parse(String(init?.body)) });
    return Promise.resolve(new Response(null, { status: 204 }));
  }) as typeof fetch;
  const svc = service({ origin: "https://a.example", broker: "https://b.example", crud: "http://crud", serviceJwt: "t", document: JSON.stringify({ owner: "o", plans: { analysis: {} } }), fetcher });
  const res = await svc(new Request("https://a.example/billing/events", { method: "POST", body: token }));
  await res.body?.cancel();
  return { status: res.status, calls };
}

Deno.test("an entitlement with a trial writes the trial's state; one without writes none", async () => {
  const trial = { state: "cancelled", amount: 1990, currency: "brl", charges_at: 1_800_000_000 };
  const withTrial = await pushed({ trial });
  eq(withTrial.status, 204);
  eq(withTrial.calls.map((c) => c.fn), ["billing_entitle", "billing_trial_state"]);
  eq(withTrial.calls[1].args, { account: ANA_ID, state: "cancelled", plan: "analysis", amount: 1990, currency: "brl", charges_at: "2027-01-15T08:00:00.000Z", ver: 5 });
  const without = await pushed({});
  eq([without.status, without.calls.map((c) => c.fn)], [204, ["billing_entitle"]], "an entitlement without a trial claim still passes");
});

Deno.test("a malformed trial claim is refused", async () => {
  for (const trial of [null, "running", { state: "paused", amount: 1, currency: "brl", charges_at: 1 }, { state: "running", amount: "1", currency: "brl", charges_at: 1 },
    { state: "running", amount: 1, currency: 5, charges_at: 1 }, { state: "running", amount: 1, currency: "brl" }, { state: "running", amount: 1.5, currency: "brl", charges_at: 1 }]) {
    const r = await pushed({ trial });
    eq([JSON.stringify(trial), r.status, r.calls.length], [JSON.stringify(trial), 400, 0], "nothing written");
  }
});

Deno.test("a trial state the database would not take fails the push, so the broker tries again", async () => {
  const { token, jwk } = await signed({ trial: { state: "running", amount: 1, currency: "brl", charges_at: 1_800_000_000 } });
  const fetcher = ((input: string | URL | Request) => {
    const url = String(input);
    if (url === "https://b.example/jwks") return Promise.resolve(Response.json({ keys: [jwk] }));
    return Promise.resolve(url.endsWith("billing_trial_state") ? new Response("boom", { status: 500 }) : new Response(null, { status: 204 }));
  }) as typeof fetch;
  const svc = service({ origin: "https://a.example", broker: "https://b.example", crud: "http://crud", serviceJwt: "t", document: JSON.stringify({ owner: "o", plans: { analysis: {} } }), fetcher });
  const res = await svc(new Request("https://a.example/billing/events", { method: "POST", body: token }));
  eq(res.status, 502, "not taken");
});

Deno.test("the door flag is read with the reader's own session and told to the broker; a flag that does not answer fails the call", async () => {
  const on = trialStage();
  const res = await on.ask(on.make({ doorFlag: "stripe_door" }), "/billing/trial");
  eq(res.status, 200, "on");
  await res.body?.cancel();
  eq(on.doorAsks, [{ auth: "Bearer reader", body: { context: { targetingKey: ANA_ID } } }], "asked as the reader, for the reader");
  eq(on.broker.map((b) => b.body.door), [true], "the broker is told");
  const off = trialStage({ door: () => Response.json({ value: false }) });
  await (await off.ask(off.make({ doorFlag: "stripe_door" }), "/billing/trial")).body?.cancel();
  eq(off.broker.map((b) => b.body.door), [false], "off is told too");
  const none = trialStage();
  await (await none.ask(none.make(), "/billing/trial")).body?.cancel();
  eq([none.doorAsks.length, "door" in none.broker[0].body], [0, false], "no door flag: nothing asked, nothing told");
  const absent = trialStage({ door: () => Response.json({ key: "stripe_door", errorCode: "FLAG_NOT_FOUND" }, { status: 404 }) });
  const missing = await absent.ask(absent.make({ doorFlag: "stripe_door" }), "/billing/trial");
  eq([missing.ok, absent.broker.length], [false, 0], "a flag that is not there fails loudly");
  await missing.body?.cancel();
  const down = trialStage({ door: () => new Response("", { status: 503 }) });
  const failed = await down.ask(down.make({ doorFlag: "stripe_door" }), "/billing/trial");
  eq([failed.ok, down.broker.length], [false, 0], "a flag that does not answer sends nothing to the broker");
  await failed.body?.cancel();
});

// The grants loop keeps the startup race out of the logs (PRONTO-295, from Bonk Chess's copy): billing starts
// before crud listens, so a refusal in the first minute says nothing, one after it warns, and after a success
// any failure is an error.
Deno.test("a failed grants call is quiet in the startup window, a warning after it, an error once served", () => {
  eq(grantLog(false, 2000), "none", "crud is not listening yet at every instance start");
  eq(grantLog(false, 59000), "none");
  eq(grantLog(false, 70000), "warn", "still not written after the window");
  eq(grantLog(true, 2000), "error", "after a success it is real trouble");
});
