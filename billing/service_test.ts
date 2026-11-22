// The service hands the author's grants to the database: the release's set, or
// the flag billing_grants as flagd serves it now; each set once, and none taken
// away because flagd could not be asked.
import { grantsLoop, grantVerdict, NotReady, service } from "./service.ts";
import { entitlementClaims } from "./broker/core.ts";
import { RULES } from "./rules.ts";
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
function trialStage(o: { strict?: () => Response; flag?: () => Response; status?: Record<string, unknown>; offer?: () => Response; checkout?: () => Response; document?: unknown; consent?: unknown; door?: () => Response } = {}) {
  const calls: { fn: string; args: Record<string, unknown> }[] = [];
  const broker: { path: string; body: Record<string, unknown> }[] = [];
  const flagBodies: unknown[] = [];
  const flagAsks: { url: string; headers: Record<string, string> }[] = [];
  const doorAsks: { auth: string | null; account: string | null; body: unknown }[] = [];
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
    if (/^(http:\/\/flagd:8693|http:\/\/localhost:3500|https:\/\/a\.example)\/ofrep\/v1\/evaluate\/flags\/free_trial$/.test(url)) {
      flagBodies.push(body);
      flagAsks.push({ url, headers: Object.fromEntries(new Headers(init?.headers)) });
      return Promise.resolve(o.flag ? o.flag() : Response.json({ value: true }));
    }
    if (url.endsWith("/ofrep/v1/evaluate/flags/billing_strict")) return Promise.resolve(o.strict ? o.strict() : Response.json({ value: true }));
    if (/^(http:\/\/flagd:8693|https:\/\/a\.example)\/ofrep\/v1\/evaluate\/flags\/stripe_door$/.test(url)) {
      const h = new Headers(init?.headers);
      doorAsks.push({ auth: h.get("authorization"), account: h.get("x-pronto-account"), body });
      return Promise.resolve(o.door ? o.door() : Response.json({ value: true }));
    }
    if (url === "https://b.example/route") {
      broker.push({ path: "/route", body });
      return Promise.resolve(Response.json({ transport: (body as { door?: boolean }).door ? "door" : "direct" }));
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
  return { calls, broker, flagBodies, flagAsks, doorAsks, make, ask };
}
const fns = (calls: { fn: string }[]) => calls.map((c) => c.fn);
const CONSENT = { plan: "analysis", amount: 1990, currency: "brl", charges_at: "2027-02-05T12:00:00Z", terms: "Free until Feb 5, then R$ 19,90 a month.", consent: true, locale: "pt-BR", return: "/?premium=trial" };

Deno.test("the trial is off when its flag is off: 404; with the strict flag on a flag that cannot be asked fails the request: 502, with it off the trial is off; nothing asked of the broker", async () => {
  const cases: [string, () => Response, number][] = [
    ["false", () => Response.json({ value: false }), 404],
    ["not a boolean", () => Response.json({ value: "true" }), 502],
    ["flag not found", () => Response.json({ errorCode: "FLAG_NOT_FOUND" }, { status: 404 }), 502],
    ["flagd down", () => new Response("", { status: 503 }), 502],
    ["flagd unreachable", () => { throw new TypeError("connection refused"); }, 502],
  ];
  const quietly = console.warn;
  console.warn = () => {};
  try {
    for (const [why, flag, status] of cases) {
      // The door path (stripe_door true for the reader) is strict; any other reader keeps the trial off, as before the door.
      for (const [way, settings, expected] of [["strict flag on", { strictFlag: "billing_strict" }, status], ["strict flag off", {}, 404]] as const) {
        const t = trialStage({ flag });
        for (const [path, body] of [["/billing/trial", {}], ["/billing/trial/checkout", CONSENT], ["/billing/trial/consent", { account: ANA_ID, ticket: "t".repeat(32) }]] as const) {
          const res = await t.ask(t.make(settings), path, body);
          eq([why, way, path, res.status], [why, way, path, expected], expected === 404 ? "off" : "no answer is no trial, and says so");
          await res.body?.cancel();
        }
        eq(t.broker, [], `${why}, ${way}: no broker call`);
        eq(fns(t.calls).filter((f) => f.startsWith("billing_trial")), [], `${why}, ${way}: no trial function called`);
      }
    }
  } finally {
    console.warn = quietly;
  }
  // A flag configured with nowhere to ask it fails too on the door path (the door flag itself needs flagd, so
  // there it is its own 502); a document that has no trial is off.
  const noFlagd = trialStage();
  eq((await noFlagd.ask(noFlagd.make({ flags: undefined }), "/billing/trial")).status, 404, "no flagd to ask: off, as before the door");
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
  // An old broker has no /trial/offer: its refusal is the answer, never an ineligible account.
  const old = trialStage({ offer: () => Response.json({ error: "not found" }, { status: 404 }) });
  const res = await old.ask(old.make({ strictFlag: "billing_strict" }), "/billing/trial");
  eq(res.status, 404, "with the strict flag on an old broker's refusal is passed on");
  await res.body?.cancel();
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

// PRONTO-82: the door's /ofrep/ reads the account from a session alone, and the broker's consent check
// carries none, so the trial's per-account flag is asked of flagd directly: told the account and the
// host in the headers flagd reads them from (--context-from-header), as the door would tell it.
Deno.test("asked directly, flagd is told the account and the host; through the mesh, by the sidecar's address", async () => {
  const direct = trialStage();
  for (const [path, body] of [["/billing/trial", {}], ["/billing/trial/consent", { account: ANA_ID, ticket: "t".repeat(32) }]] as const) {
    await (await direct.ask(direct.make(), path, body)).body?.cancel();
  }
  eq(direct.flagAsks.map((a) => [a.url, a.headers["x-pronto-account"], a.headers["x-pronto-host"], a.headers.authorization]),
    Array(2).fill(["http://flagd:8693/ofrep/v1/evaluate/flags/free_trial", ANA_ID, "a.example", undefined]), "the reader's and the broker's asks alike");
  const mesh = trialStage();
  await (await mesh.ask(mesh.make({ flags: "mesh" }), "/billing/trial/consent", { account: ANA_ID, ticket: "t".repeat(32) })).body?.cancel();
  eq(mesh.flagAsks.map((a) => [a.url, a.headers["dapr-app-id"], a.headers["x-pronto-account"]]),
    [["http://localhost:3500/ofrep/v1/evaluate/flags/free_trial", "flagd", ANA_ID]], "the pod's sidecar, to the app-id flagd");
  const door = trialStage();
  await (await door.ask(door.make({ flags: "origin" }), "/billing/trial/consent", { account: ANA_ID, ticket: "t".repeat(32) })).body?.cancel();
  eq(door.flagAsks.map((a) => [a.url, a.headers["x-pronto-account"], a.headers["x-pronto-host"]]),
    [["https://a.example/ofrep/v1/evaluate/flags/free_trial", undefined, undefined]], "the door says both itself: the page's headers would be stripped");
});

Deno.test("the door flag is read for the reader and told to the broker; a lookup that fails in transit fails the call, a flag that is not there fails the call", async () => {
  const on = trialStage();
  const res = await on.ask(on.make({ doorFlag: "stripe_door" }), "/billing/trial");
  eq(res.status, 200, "on");
  await res.body?.cancel();
  eq(on.doorAsks, [{ auth: null, account: ANA_ID, body: { context: { targetingKey: ANA_ID } } }], "asked of flagd directly, for the reader");
  const viaDoor = trialStage();
  await (await viaDoor.ask(viaDoor.make({ doorFlag: "stripe_door", flags: "origin" }), "/billing/trial")).body?.cancel();
  eq(viaDoor.doorAsks.map((a) => [a.auth, a.account]), [["Bearer reader", null]], "through the door, with the reader's own session");
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
  // A lookup that fails in transit fails the request, never the flag-off path: the broker would call
  // Stripe straight, past the airlock's ledger. Only an answer flagd gave picks a way.
  const transit: [string, () => Response][] = [
    ["flagd 503", () => new Response("", { status: 503 })],
    ["flagd 500", () => new Response("", { status: 500 })],
    ["fetch rejects", () => Promise.reject(new TypeError("connection refused")) as unknown as Response],
    ["times out", () => Promise.reject(new DOMException("The signal timed out", "TimeoutError")) as unknown as Response],
    ["body cannot be read", () => new Response(new ReadableStream({ pull(c) { c.error(new TypeError("body interrupted")); } }), { status: 200 })],
    ["body not JSON", () => new Response("{not json", { status: 200 })],
  ];
  const quiet = console.error;
  console.error = () => {};
  try {
    for (const [why, door] of transit) {
      const t = trialStage({ door });
      const r = await t.ask(t.make({ doorFlag: "stripe_door" }), "/billing/trial");
      eq([why, r.status, t.broker.length], [why, 502, 0], "fails the request, the broker is not called");
      await r.body?.cancel();
    }
  } finally {
    console.error = quiet;
  }
  const odd = trialStage({ door: () => Response.json({ value: "yes" }) });
  const bad = await odd.ask(odd.make({ doorFlag: "stripe_door" }), "/billing/trial");
  eq([bad.ok, odd.broker.length], [false, 0], "an answer that is no boolean fails");
  await bad.body?.cancel();
});

// The grants loop waits out the startup race (PRONTO-295, from Bonk Chess's copy): billing starts before crud
// listens, so a neighbour not up yet is waited for in the first minute. Any other failure, a wait past the
// window and any failure after a success is a fail: /billing/health goes 503.
Deno.test("a neighbour not up yet is waited for in the startup window; any other failure fails", () => {
  eq(grantVerdict(false, 2000, true), "wait", "crud is not listening yet at every instance start");
  eq(grantVerdict(false, 4000, true), "wait", "the same wait, later in the window");
  eq(grantVerdict(false, 70000, true), "fail", "still not written after the window");
  eq(grantVerdict(true, 2000, true), "fail", "after a success it is real trouble");
  eq(grantVerdict(false, 2000, false), "fail", "a refusal no wait can mend fails at once");
});

// `strict`: whether the strict flag evaluates true (the strict handling) or false (the earlier behaviour, exactly).
function healthStage(answer: () => Response | Promise<Response>, strict = true) {
  const fetcher = ((input: string | URL | Request) => {
    const url = String(input);
    if (url === "http://crud/rpc/billing_grant") return Promise.resolve().then(answer);
    if (url.endsWith("/billing_strict")) return Promise.resolve(Response.json({ value: strict }));
    if (url.endsWith("/billing_grants")) return Promise.resolve(Response.json({ value: "[]" }));
    return Promise.resolve(new Response("", { status: 404 }));
  }) as typeof fetch;
  const s = service({ origin: "https://a.example", broker: "https://b.example", crud: "http://crud", serviceJwt: "t", document: JSON.stringify({ owner: "o", plans: { analysis: {} } }), flags: "http://flagd:8693", strictFlag: "billing_strict", fetcher });
  const health = async () => {
    const r = await s(new Request("https://a.example/billing/health"));
    const body = await r.json();
    return [r.status, body];
  };
  return { s, health };
}

async function quiet<T>(f: () => Promise<T>): Promise<T> {
  const error = console.error, log = console.log;
  console.error = () => {};
  console.log = () => {};
  try { return await f(); } finally { console.error = error; console.log = log; }
}

Deno.test("a grants write no wait can mend turns /billing/health 503 until a success", async () => {
  for (const [why, status] of [["token refused", 401], ["SQL error", 400]] as const) {
    let ok = false;
    const { s, health } = healthStage(() => ok ? new Response(null, { status: 204 }) : Response.json({ code: "X" }, { status }));
    eq(await health(), [200, { ok: true }], `${why}: healthy before the first try`);
    await quiet(async () => { eq((await s.attempt(1000)), false, `${why}: not written`); });
    eq(await health(), [503, { error: "grants not written" }], `${why}: unhealthy`);
    await quiet(async () => { eq((await s.attempt(2000)), false, `${why}: still refused`); });
    eq(await health(), [503, { error: "grants not written" }], `${why}: still unhealthy`);
    ok = true;
    eq(await s.attempt(3000), true, `${why}: written`);
    eq(await health(), [200, { ok: true }], `${why}: a later success is healthy again`);
  }
});

Deno.test("a failure after a first success turns /billing/health 503, a later success clears it", async () => {
  const flags = { value: "[]" };
  const fetcher = ((input: string | URL | Request) => {
    const url = String(input);
    if (url === "http://crud/rpc/billing_grant") return Promise.resolve(new Response(null, { status: 204 }));
    if (url.endsWith("/billing_strict")) return Promise.resolve(Response.json({ value: true }));
    if (url.endsWith("/billing_grants")) return Promise.resolve(flags.value === "down" ? new Response("", { status: 500 }) : Response.json({ value: flags.value }));
    return Promise.resolve(new Response("", { status: 404 }));
  }) as typeof fetch;
  const f = service({ origin: "https://a.example", broker: "https://b.example", crud: "http://crud", serviceJwt: "t", document: JSON.stringify({ owner: "o", plans: { analysis: {} } }), flags: "http://flagd:8693", strictFlag: "billing_strict", fetcher });
  const h = async () => (await f(new Request("https://a.example/billing/health"))).status;
  eq(await f.attempt(0), true, "flag read and written");
  flags.value = "down";
  await quiet(async () => { eq((await f.attempt(1000)), false, "flagd down after a success"); });
  eq(await h(), 503, "a failure after a success fails even inside the window");
  flags.value = JSON.stringify(ANA);
  eq(await f.attempt(2000), true, "a corrected push is written");
  eq(await h(), 200, "healthy again, no deploy");
});

Deno.test("a neighbour not up yet keeps /billing/health 200 in the window and 503 after it", async () => {
  const { s, health } = healthStage(() => new Response("", { status: 503 }));
  await quiet(async () => { eq(await s.attempt(2000), false, "not written yet"); });
  eq(await health(), [200, { ok: true }], "waiting inside the window is healthy");
  await quiet(async () => { eq((await s.attempt(70000)), false, "past the window it fails"); });
  eq(await health(), [503, { error: "grants not written" }], "past the window it is not");
});

Deno.test("what a failed grants call is: not up yet, or a failure", async () => {
  const cases: [string, () => Response, boolean][] = [
    ["connection refused", () => { throw new TypeError("error sending request", { cause: new Error("tcp connect error: Connection refused (os error 61)") }); }, true],
    ["name not resolved", () => { throw new TypeError("error sending request", { cause: new Error("failed to lookup address information: nodename nor servname provided") }); }, false],
    ["gateway not serving", () => new Response("", { status: 503 }), true],
    ["schema not reloaded", () => Response.json({ code: "PGRST202", message: "Could not find the function public.billing_grant" }, { status: 404 }), true],
    ["token refused", () => Response.json({ code: "PGRST301" }, { status: 401 }), false],
    ["SQL error", () => Response.json({ code: "22P02", message: "invalid input" }, { status: 400 }), false],
  ];
  for (const [why, answer, notReady] of cases) {
    const fetcher = (() => Promise.resolve().then(answer)) as typeof fetch;
    const s = service({ origin: "https://a.example", broker: "https://b.example", crud: "http://crud", serviceJwt: "t", document: JSON.stringify({ owner: "o", plans: { analysis: {} } }), grants: "[]", fetcher });
    const e = await s.grant(true).then(() => null, (x) => x);
    eq([why, e instanceof Error, e instanceof NotReady], [why, true, notReady], why);
  }
});

Deno.test("a changed grant write that times out is written again when the flag goes back to the old set", async () => {
  let value = JSON.stringify(ANA), timeout = false;
  const handed: unknown[] = [];
  const fetcher = ((input: string | URL | Request, init?: RequestInit) => {
    const url = String(input);
    if (url === "http://crud/rpc/billing_grant") {
      handed.push(JSON.parse(String(init?.body)).grants);
      return timeout ? Promise.reject(new DOMException("The signal timed out", "TimeoutError")) : Promise.resolve(new Response(null, { status: 204 }));
    }
    return Promise.resolve(Response.json({ value }));
  }) as typeof fetch;
  const s = service({ origin: "https://a.example", broker: "https://b.example", crud: "http://crud", serviceJwt: "t", document: JSON.stringify({ owner: "o", plans: { analysis: {} } }), flags: "http://flagd:8693", fetcher });
  await s.grant(true);
  value = "[]";
  timeout = true; // the write of [] may have committed
  await s.grant(true).then(() => { throw new Error("should time out"); }, () => {});
  value = JSON.stringify(ANA);
  timeout = false;
  await s.grant(true);
  eq(handed, [ANA, [], ANA], "the old set is written again: the database may hold []");
});

Deno.test("the grants loop backs off and keeps going after a failure, never ending the process", async () => {
  const slept: number[] = [];
  const sleep = (ms: number) => { slept.push(ms); return Promise.resolve(); };
  const script = (steps: boolean[]) => ({ attempt: (_: number) => Promise.resolve(steps.shift()!) });
  await grantsLoop(script([false, false, true]), { repeat: false, sleep });
  eq(slept, [2000, 4000], "waits double, then it returns once written");
  slept.length = 0;
  // With flags it never returns: the script ends the run by throwing from its sleep.
  const steps = [false, false, false, false, false, false, false, true, false];
  const stop = new Error("test over");
  let rounds = 0;
  const err = await grantsLoop(script(steps), { repeat: true, sleep: (ms) => { slept.push(ms); if (++rounds === 9) throw stop; return Promise.resolve(); } }).then(() => "returned", (e) => e);
  eq([err === stop, slept], [true, [2000, 4000, 8000, 16000, 32000, 60000, 60000, 60000, 60000]], "capped at a minute, a success waits a minute, a failure after one backs off again");
});

Deno.test("a probe whose door lookup fails gets a 502 and neither transport is called", async () => {
  const quietly = console.error;
  console.error = () => {};
  try {
    for (const [why, door] of [["flagd 503", () => new Response("", { status: 503 })], ["fetch rejects", () => Promise.reject(new TypeError("connection refused")) as unknown as Response]] as const) {
      const t = trialStage({ door });
      const res = await t.make({ doorFlag: "stripe_door" })(new Request("https://a.example/billing/probe", { headers: { authorization: "Bearer reader" } }));
      eq([why, res.status, t.broker.length], [why, 502, 0], "a 502, and nothing sent to the broker (so to neither transport)");
      await res.body?.cancel();
    }
  } finally {
    console.error = quietly;
  }
});

Deno.test("a broker that does not know trials: no offers with the strict flag off, a failed request with it on", async () => {
  for (const [way, settings, status] of [["strict flag off", {}, 200], ["strict flag on", { strictFlag: "billing_strict" }, 404]] as const) {
    const t = trialStage({ offer: () => Response.json({ error: "not found" }, { status: 404 }) });
    const res = await t.ask(t.make(settings), "/billing/trial");
    eq([way, res.status], [way, status]);
    if (status === 200) eq(await res.json(), { state: null, plan: null, amount: null, currency: null, charges_at: null, holds: false, eligible: false, offers: [] }, "none offered");
    else await res.body?.cancel();
  }
});

Deno.test("a failed door lookup fails both trial requests before the flag is asked and before any ticket is evaluated, issued or consumed", async () => {
  const quietly = console.error;
  console.error = () => {};
  try {
    for (const [why, door] of [["flagd 503", () => new Response("", { status: 503 })], ["fetch rejects", () => Promise.reject(new TypeError("connection refused")) as unknown as Response]] as const) {
      const t = trialStage({ door });
      for (const [path, body] of [["/billing/trial", {}], ["/billing/trial/checkout", CONSENT]] as const) {
        const res = await t.ask(t.make({ doorFlag: "stripe_door" }), path, body);
        eq([why, path, res.status], [why, path, 502]);
        await res.body?.cancel();
      }
      eq(t.flagBodies, [], `${why}: the trial flag was not asked`);
      eq(fns(t.calls).filter((f) => f === "billing_trial_ask" || f === "billing_trial_take"), [], `${why}: the ticket is still available`);
      eq(t.broker, [], `${why}: the broker was not called`);
    }
  } finally {
    console.error = quietly;
  }
});

Deno.test("with no strict flag set, the service behaves as it did: health stays 200 on a failed grants write, trial lookups are off on failure", async () => {
  const { s, health } = healthStage(() => Response.json({ code: "X" }, { status: 401 }), false);
  const logged: string[] = [];
  const error = console.error;
  console.error = (...a: unknown[]) => { logged.push(a.join(" ")); };
  try {
    eq(await s.attempt(1000, 4), false, "not written");
    eq(await health(), [200, { ok: true }], "health is as it was");
    eq(logged, [], "inside the window nothing is logged, as before");
  } finally {
    console.error = error;
  }
  // No strictFlag at all: the same.
  const none = service({ origin: "https://a.example", broker: "https://b.example", crud: "http://crud", serviceJwt: "t", document: JSON.stringify({ owner: "o", plans: { analysis: {} } }), grants: "[]", fetcher: (() => Promise.resolve(Response.json({}, { status: 401 }))) as typeof fetch });
  await quiet(async () => { eq(await none.attempt(1000), false); });
  eq((await none(new Request("https://a.example/billing/health"))).status, 200, "no strict flag: health is as it was");
});

Deno.test("a flagd that cannot say whether the strict flag is on keeps the mode and the error: health stays 503 until a write is confirmed", async () => {
  const flagd = { strict: "true" as "true" | "down", grants: "ok" as "ok" | "down" }, writes = { ok: false };
  const fetcher = ((input: string | URL | Request) => {
    const url = String(input);
    if (url === "http://crud/rpc/billing_grant") return Promise.resolve(writes.ok ? new Response(null, { status: 204 }) : Response.json({ code: "22P02" }, { status: 400 }));
    if (url.endsWith("/billing_strict")) return Promise.resolve(flagd.strict === "down" ? new Response("", { status: 500 }) : Response.json({ value: true }));
    if (url.endsWith("/billing_grants")) return Promise.resolve(flagd.grants === "down" ? new Response("", { status: 500 }) : Response.json({ value: "[]" }));
    return Promise.resolve(new Response("", { status: 404 }));
  }) as typeof fetch;
  const svc = service({ origin: "https://a.example", broker: "https://b.example", crud: "http://crud", serviceJwt: "t", document: JSON.stringify({ owner: "o", plans: { analysis: {} } }), flags: "http://flagd:8693", strictFlag: "billing_strict", fetcher });
  const health = async () => (await svc(new Request("https://a.example/billing/health"))).status;
  await quiet(async () => {
    eq(await svc.attempt(1000), false, "a write refused");
    eq(await health(), 503, "unhealthy");
    // flagd now down for everything: the strict flag cannot be read, nor the grants flag, nor can the write be made.
    flagd.strict = "down";
    flagd.grants = "down";
    eq(await svc.attempt(2000), false, "still not written");
    eq(await health(), 503, "a failed flag read does not clear the error");
    // The strict flag unreadable, the grants flag back, the write still refused: still unhealthy.
    flagd.grants = "ok";
    eq(await svc.attempt(3000), false);
    eq(await health(), 503, "the error stays until a write is confirmed");
    writes.ok = true;
    eq(await svc.attempt(4000), true, "written");
    eq(await health(), 200, "a confirmed write clears it");
  });
});

Deno.test("a strict flag that answers false leaves the strict mode and its error, as the earlier behaviour", async () => {
  const state = { strict: true };
  const fetcher = ((input: string | URL | Request) => {
    const url = String(input);
    if (url === "http://crud/rpc/billing_grant") return Promise.resolve(Response.json({ code: "22P02" }, { status: 400 }));
    if (url.endsWith("/billing_strict")) return Promise.resolve(Response.json({ value: state.strict }));
    return Promise.resolve(Response.json({ value: "[]" }));
  }) as typeof fetch;
  const svc = service({ origin: "https://a.example", broker: "https://b.example", crud: "http://crud", serviceJwt: "t", document: JSON.stringify({ owner: "o", plans: { analysis: {} } }), flags: "http://flagd:8693", strictFlag: "billing_strict", fetcher });
  await quiet(async () => {
    await svc.attempt(1000);
    eq((await svc(new Request("https://a.example/billing/health"))).status, 503);
    state.strict = false;
    await svc.attempt(2000);
    eq((await svc(new Request("https://a.example/billing/health"))).status, 200, "answered false: health as it was");
  });
});

Deno.test("GET /billing/route asks the broker for the transport of the door word evaluated for no one, and answers it", async () => {
  for (const [door, word, transport] of [[true, true, "door"]] as const) {
    const t = trialStage({ door: () => Response.json({ value: door }) });
    const res = await t.make({ doorFlag: "stripe_door" })(new Request("https://a.example/billing/route"));
    eq([res.status, await res.json()], [200, { ok: true, door: word, transport }], `door ${door}`);
    eq(t.doorAsks.map((a) => [a.auth, a.account]), [[null, null]], "asked as no one: no session, no account");
    eq(t.broker, [{ path: "/route", body: { tenant: "https://a.example", door: word } }], "the broker is asked, with the door word");
  }
  // Off until its flag: no door flag configured, or the flag off for no one, is 404 and the broker is never asked.
  const unset = trialStage();
  const none = await unset.make()(new Request("https://a.example/billing/route"));
  eq([none.status, unset.broker.length, unset.doorAsks.length], [404, 0, 0], "unset flag: absent, nothing asked");
  await none.body?.cancel();
  const off = trialStage({ door: () => Response.json({ value: false }) });
  const gone = await off.make({ doorFlag: "stripe_door" })(new Request("https://a.example/billing/route"));
  eq([gone.status, off.broker.length], [404, 0], "flag off: absent");
  await gone.body?.cancel();
});

Deno.test("GET /billing/route with a failed door lookup is a 502 and the broker is not asked", async () => {
  const quietly = console.error;
  console.error = () => {};
  try {
    for (const door of [() => new Response("", { status: 503 }), () => Promise.reject(new TypeError("connection refused")) as unknown as Response]) {
      const t = trialStage({ door });
      const res = await t.make({ doorFlag: "stripe_door" })(new Request("https://a.example/billing/route"));
      eq([res.status, t.broker.length], [502, 0]);
      await res.body?.cancel();
    }
  } finally {
    console.error = quietly;
  }
});

Deno.test("a configured strict flag that cannot be asked fails a trial request instead of reading as off", async () => {
  for (const strict of [() => new Response("", { status: 500 }), () => Response.json({ value: "yes" })]) {
    const t = trialStage({ strict });
    const res = await t.ask(t.make({ strictFlag: "billing_strict" }), "/billing/trial");
    eq([res.status, t.broker.length], [502, 0], "no answer is a failure, and nothing is asked of the broker");
    await res.body?.cancel();
  }
  const unset = trialStage({ strict: () => new Response("", { status: 500 }) });
  eq((await unset.ask(unset.make(), "/billing/trial")).status, 200, "no strict flag configured: nothing is asked");
});

Deno.test("GET /billing/route meters an anonymous probe before it reaches flagd or the broker", async () => {
  const t = trialStage();
  const svc = t.make({ doorFlag: "stripe_door" });
  const get = () => svc(new Request("https://a.example/billing/route", { headers: { "x-forwarded-for": "9.9.9.9" } }));
  const statuses: number[] = [];
  for (let i = 0; i < 31; i++) {
    const r = await get();
    statuses.push(r.status);
    await r.body?.cancel();
  }
  eq([statuses.filter((x) => x === 200).length, statuses.at(-1)], [30, 429], "30 a client a minute, then refused");
  eq([t.doorAsks.length, t.broker.length], [30, 30], "the refused one reached neither flagd nor the broker");
});

Deno.test("a failed first strict-flag lookup, with a grants error outstanding, is strict: health stays 503; unset stays legacy", async () => {
  const fetcher = ((input: string | URL | Request) => {
    const url = String(input);
    if (url === "http://crud/rpc/billing_grant") return Promise.resolve(Response.json({ code: "22P02" }, { status: 400 }));
    if (url.endsWith("/billing_strict")) return Promise.resolve(new Response("", { status: 500 }));
    return Promise.resolve(Response.json({ value: "[]" }));
  }) as typeof fetch;
  const base = { origin: "https://a.example", broker: "https://b.example", crud: "http://crud", serviceJwt: "t", document: JSON.stringify({ owner: "o", plans: { analysis: {} } }), flags: "http://flagd:8693", fetcher };
  const strict = service({ ...base, strictFlag: "billing_strict" });
  await quiet(async () => {
    eq(await strict.attempt(1000), false);
    eq((await strict(new Request("https://a.example/billing/health"))).status, 503, "no previous answer: counted as strict");
    const legacy = service(base);
    eq(await legacy.attempt(1000), false);
    eq((await legacy(new Request("https://a.example/billing/health"))).status, 200, "no strict flag configured: legacy");
  });
});

Deno.test("the route meter's window is rules.cue's: a client is let through again once it has passed", async () => {
  const t = trialStage();
  const svc = t.make({ doorFlag: "stripe_door" });
  const now = Date.now;
  let skew = 0;
  Date.now = () => now() + skew;
  try {
    const get = async () => { const r = await svc(new Request("https://a.example/billing/route", { headers: { "x-forwarded-for": "8.8.8.8" } })); await r.body?.cancel(); return r.status; };
    for (let i = 0; i < RULES.routeLimits.perClient; i++) await get();
    eq(await get(), 429, "past the quota");
    skew = RULES.routeLimits.windowMs;
    eq(await get(), 200, "a new window after the declared one");
  } finally {
    Date.now = now;
  }
});
