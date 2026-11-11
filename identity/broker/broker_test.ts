// The broker end to end, against a fake Google this test serves: a tenant
// signs a person in and receives an ID token only it accepts, the same person
// is a stranger to a second tenant, and a sign-in never leaves for a redirect
// that is not the tenant's.
import { base64url, type Jwk, randomToken, sha256url, verifyIdToken } from "../oidc.ts";
import { askedFlag, broker, google, type Provider } from "./main.ts";

function assertEquals(a: unknown, b: unknown, m = "") {
  if (JSON.stringify(a) !== JSON.stringify(b)) throw new Error(`${m} expected ${JSON.stringify(b)}, got ${JSON.stringify(a)}`);
}

const enc = new TextEncoder();
const pair = await crypto.subtle.generateKey(
  { name: "RSASSA-PKCS1-v1_5", modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: "SHA-256" }, true, ["sign", "verify"]);
const googleJwk = { ...(await crypto.subtle.exportKey("jwk", pair.publicKey)), kid: "g1" };
const pending = new Map<string, { nonce: string; sub: string; redirect: string; profile: boolean }>();
const fakeGoogle = async (req: Request) => {
  const url = new URL(req.url);
  if (url.pathname === "/auth") {
    const code = crypto.randomUUID();
    pending.set(code, { nonce: url.searchParams.get("nonce")!, sub: url.searchParams.get("login_hint") ?? "alice", redirect: url.searchParams.get("redirect_uri")!, profile: (url.searchParams.get("scope") ?? "").split(" ").includes("profile") });
    const to = new URL(url.searchParams.get("redirect_uri")!);
    to.searchParams.set("code", code);
    to.searchParams.set("state", url.searchParams.get("state")!);
    return Response.redirect(to.toString(), 302);
  }
  if (url.pathname === "/token") {
    const f = new URLSearchParams(await req.text());
    const c = pending.get(f.get("code") ?? "");
    pending.delete(f.get("code") ?? "");
    if (!c || f.get("client_secret") !== "op-secret" || f.get("redirect_uri") !== c.redirect) return Response.json({ error: "invalid_grant" }, { status: 400 });
    const head = base64url(enc.encode(JSON.stringify({ alg: "RS256", kid: "g1" })));
    // Google answers `profile` with the person's name and picture; "mallory" has a picture off https.
    const profile = c.profile ? { name: `  ${c.sub} Example  `, picture: c.sub === "mallory" ? "http://evil.example/x.png" : `https://lh3.googleusercontent.com/a/${c.sub}=s96-c` } : {};
    const body = base64url(enc.encode(JSON.stringify({ iss: "https://accounts.google.com", aud: "op-client", sub: c.sub, nonce: c.nonce, ...profile, exp: Math.floor(Date.now() / 1000) + 600 })));
    const sig = new Uint8Array(await crypto.subtle.sign("RSASSA-PKCS1-v1_5", pair.privateKey, enc.encode(`${head}.${body}`)));
    return Response.json({ id_token: `${head}.${body}.${base64url(sig)}` });
  }
  return new Response("not found", { status: 404 });
};
const ISSUER = "https://id.example";
// Set by the test that owns the fake Google, before any case runs.
let handler: (req: Request) => Promise<Response>;
const call = (url: string, init?: RequestInit) => handler(new Request(url, init));
const brokerKeys = async (kid: string) => ((await (await call(`${ISSUER}/jwks`)).json()).keys as Jwk[]).find((k) => k.kid === kid);

/** One sign-in as `tenant`, Google's user `who`, returning what the tenant's callback received. */
async function signIn(tenant: string, who: string, over: Record<string, string> = {}) {
  const verifier = randomToken(32);
  const q = new URLSearchParams({
    client_id: tenant, redirect_uri: `${tenant}/auth/oidc/google/callback`, response_type: "code", scope: "openid",
    state: randomToken(8), nonce: randomToken(8), provider: "google", code_challenge: await sha256url(verifier), code_challenge_method: "S256", ...over,
  });
  const shown = await call(`${ISSUER}/authorize?${q}`);
  if (shown.status !== 200) return { shown };
  const html = await shown.text();
  const go = html.match(/href="([^"]+\/authorize\/continue[^"]+)"/)![1].replace(/&#38;/g, "&");
  const toGoogle = new URL((await call(go)).headers.get("location")!);
  toGoogle.searchParams.set("login_hint", who);
  const hop = await fetch(toGoogle, { redirect: "manual" });
  await hop.body?.cancel();
  const fromGoogle = hop.headers.get("location")!;
  const landed = new URL((await call(fromGoogle)).headers.get("location")!);
  return { html, landed, verifier, q };
}

async function redeem(tenant: string, code: string, verifier: string, over: Record<string, string> = {}) {
  const res = await call(`${ISSUER}/token`, {
    method: "POST", headers: { "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({ grant_type: "authorization_code", code, client_id: tenant, redirect_uri: `${tenant}/auth/oidc/google/callback`, code_verifier: verifier, ...over }),
  });
  return { status: res.status, body: await res.json() };
}

const A = "https://app-a.example", B = "https://app-b.example";
// A moved to a new address: its sector is the origin its people's subjects were made under.
const MOVED = "https://app-a-moved.example";
const cases: [string, () => Promise<void>][] = [];


cases.push(["a tenant signs a person in and gets a token only it accepts", async () => {
  const s = await signIn(A, "alice");
  assertEquals(s.html!.includes("Sign in to <span class=\"origin\">app-a.example</span>"), true, "the page names the app");
  assertEquals(`${s.landed!.origin}${s.landed!.pathname}`, `${A}/auth/oidc/google/callback`);
  assertEquals(s.landed!.searchParams.get("state"), s.q!.get("state"));
  const t = await redeem(A, s.landed!.searchParams.get("code")!, s.verifier!);
  assertEquals(t.status, 200);
  const claims = await verifyIdToken(t.body.id_token, { alg: "ES256", issuers: [ISSUER], audience: A, nonce: s.q!.get("nonce")!, keys: brokerKeys });
  assertEquals(claims.aud, A);
  assertEquals(claims.sub === "alice", false, "never Google's own subject");
}]);

cases.push(["a tenant that asks for profile is told the person's name and picture, and one that does not, neither", async () => {
  const claimsOf = async (who: string, scope: string) => {
    const s = await signIn(A, who, { scope });
    const t = await redeem(A, s.landed!.searchParams.get("code")!, s.verifier!);
    return await verifyIdToken(t.body.id_token, { alg: "ES256", issuers: [ISSUER], audience: A, nonce: s.q!.get("nonce")!, keys: brokerKeys });
  };
  const asked = await claimsOf("carol", "openid profile");
  assertEquals([asked.name, asked.picture], ["carol Example", "https://lh3.googleusercontent.com/a/carol=s96-c"]);
  const plain = await claimsOf("carol", "openid");
  assertEquals([plain.name, plain.picture], [undefined, undefined], "openid alone tells only the subject");
  const offHttps = await claimsOf("mallory", "openid profile");
  assertEquals([offHttps.name, offHttps.picture], ["mallory Example", undefined], "a picture off https is dropped");
  const d = await (await call(`${ISSUER}/.well-known/openid-configuration`)).json();
  assertEquals(d.scopes_supported, ["openid", "profile", "email"]);
}]);

cases.push(["the same person is a stranger to another tenant, and the same to the same tenant", async () => {
  const subOf = async (tenant: string) => {
    const s = await signIn(tenant, "alice");
    const t = await redeem(tenant, s.landed!.searchParams.get("code")!, s.verifier!);
    return (await verifyIdToken(t.body.id_token, { alg: "ES256", issuers: [ISSUER], audience: tenant, nonce: s.q!.get("nonce")!, keys: brokerKeys })).sub;
  };
  const a1 = await subOf(A), a2 = await subOf(A), b = await subOf(B);
  assertEquals(a1, a2);
  assertEquals(a1 === b, false);
}]);

cases.push(["an app that moved address keeps every person's subject, under its sector, and is still a stranger to others", async () => {
  const subOf = async (tenant: string, who: string) => {
    const s = await signIn(tenant, who);
    const t = await redeem(tenant, s.landed!.searchParams.get("code")!, s.verifier!);
    return (await verifyIdToken(t.body.id_token, { alg: "ES256", issuers: [ISSUER], audience: tenant, nonce: s.q!.get("nonce")!, keys: brokerKeys })).sub;
  };
  assertEquals(await subOf(MOVED, "alice"), await subOf(A, "alice"), "the moved address answers the subject the old one did");
  assertEquals(await subOf(MOVED, "alice") === await subOf(MOVED, "bob"), false, "and each person stays their own");
  assertEquals(await subOf(MOVED, "alice") === await subOf(B, "alice"), false, "and another app still sees a stranger");
}]);

cases.push(["a tenant cannot redeem another tenant's code, nor use another's redirect", async () => {
  const s = await signIn(A, "bob");
  const stolen = await redeem(B, s.landed!.searchParams.get("code")!, s.verifier!);
  assertEquals(stolen.status, 400);
  const replay = await redeem(A, s.landed!.searchParams.get("code")!, s.verifier!);
  assertEquals(replay.status, 400, "the stolen attempt spent the code");
  const elsewhere = await signIn(A, "bob", { redirect_uri: `${B}/auth/oidc/google/callback` });
  assertEquals(elsewhere.shown!.status, 400);
  assertEquals(elsewhere.shown!.headers.get("location"), null, "never redirected");
}]);

cases.push(["a tampered round trip is refused without redirecting", async () => {
  const res = await call(`${ISSUER}/callback/google?code=x&state=${base64url(enc.encode("{}"))}.AAAA`);
  assertEquals(res.status, 400);
  assertEquals(res.headers.get("location"), null);
}]);

cases.push(["discovery and keys describe a pairwise ES256 provider", async () => {
  const d = await (await call(`${ISSUER}/.well-known/openid-configuration`)).json();
  assertEquals([d.issuer, d.subject_types_supported, d.id_token_signing_alg_values_supported, d.token_endpoint_auth_methods_supported],
    [ISSUER, ["pairwise"], ["ES256"], ["none"]]);
  const k = await (await call(`${ISSUER}/jwks`)).json();
  assertEquals([k.keys.length, k.keys[0].kty, k.keys[0].d], [1, "EC", undefined], "the public half only");
}]);


// One test owns the fake Google from start to shutdown, so no operation of
// its server outlives the test; each case is a step within it.
Deno.test("the broker end to end", async (t) => {
  const fake = Deno.serve({ port: 0, onListen() {} }, fakeGoogle);
  const G = `http://localhost:${fake.addr.port}`;
  const provider: Provider = {
    name: "google", label: "Google", authUrl: `${G}/auth`, tokenUrl: `${G}/token`, issuers: ["https://accounts.google.com"],
    keys: async (kid) => (kid === "g1" ? googleJwk : undefined), clientId: "op-client", clientSecret: "op-secret",
  };
  handler = await broker({ issuer: ISSUER, secret: "s".repeat(40), providers: [provider], sectors: new Map([[MOVED, A]]) });
  try {
    for (const [name, run] of cases) await t.step({ name, fn: run, sanitizeOps: false, sanitizeResources: false });
  } finally {
    await fake.shutdown();
  }
});

// Google's token exchange through the airlock's door (PRONTO-268, flag signin_door), the door faked:
// the airlock adds the client's secret (here, the fake door does, as the airlock does) and the broker's
// own request carries none.
Deno.test("the token exchange through the airlock's door, as the tenant's flag signin_door asks", async () => {
  const fake = Deno.serve({ port: 0, onListen() {} }, fakeGoogle);
  const G = `http://localhost:${fake.addr.port}`;
  const sent: { url: string; body: Record<string, unknown> }[] = [];
  const fetcher: typeof fetch = async (url, init) => {
    const body = JSON.parse(String(init!.body));
    sent.push({ url: String(url), body });
    const form = new URLSearchParams(body.body);
    form.set("client_secret", "op-secret");
    const res = await fetch(`${G}${body.path}`, { method: body.method, headers: { "content-type": body.contentType }, body: form });
    return Response.json({ status: res.status, body: await res.json(), replayed: false });
  };
  const asked: string[] = [];
  const flag: Record<string, boolean> = { [A]: true, [B]: false };
  const make = async (over: Partial<Provider>) => {
    const provider: Provider = {
      name: "google", label: "Google", authUrl: `${G}/auth`, tokenUrl: `${G}/token`, issuers: ["https://accounts.google.com"],
      keys: async (kid) => (kid === "g1" ? googleJwk : undefined), clientId: "op-client", ...over,
    };
    handler = await broker({ issuer: ISSUER, secret: "s".repeat(40), providers: [provider], fetcher, askDoor: (t) => { asked.push(t); return Promise.resolve(flag[t] === true); } });
  };
  const signedIn = async (tenant: string) => {
    const s = await signIn(tenant, "alice");
    return s.landed!.searchParams.has("code");
  };
  try {
    // The door alone: the airlock holds the credential, the broker none.
    await make({ door: "http://airlock:9998/door/google" });
    assertEquals(await signedIn(A), true, "signed in through the door");
    assertEquals(sent.length, 1);
    assertEquals(sent[0].url, "http://airlock:9998/door/google");
    const b = sent[0].body;
    assertEquals([b.method, b.path, b.contentType], ["POST", "/token", "application/x-www-form-urlencoded"]);
    assertEquals(/^code-[0-9a-f]{64}$/.test(String(b.key)), true, "a key of the code's own");
    assertEquals(String(b.body).includes("op-secret") || String(b.body).includes("client_secret"), false, "no secret in the body");
    assertEquals(new URLSearchParams(String(b.body)).get("client_id"), "op-client");
    assertEquals(asked, [], "no flag asked: the door is the only way");

    // While the flag moves it (door-asked): the broker keeps its secret; the tenant's flag picks the way.
    sent.length = 0;
    await make({ door: "http://airlock:9998/door/google", doorAsked: true, doorTenants: [A, B], clientSecret: "op-secret" });
    assertEquals(await signedIn(A), true);
    assertEquals(sent.length, 1, "flag on: through the door");
    assertEquals(await signedIn(B), true, "flag off: straight to Google, with the broker's secret");
    assertEquals(sent.length, 1, "flag off: the door is not called");
    assertEquals(asked.slice(-2), [A, B], "each sign-in asks its own tenant's flag");
    // A tenant the operator did not list is never asked (it may have no signin_door): straight to Google.
    assertEquals(await signedIn("https://app-c.example"), true);
    assertEquals(sent.length, 1, "unlisted: the door is not called");
    assertEquals(asked.includes("https://app-c.example"), false, "unlisted: its flag is not asked");

    // A door that answers nothing fails the sign-in as a refused exchange does: back to the tenant, no code.
    const down: typeof fetch = () => Promise.resolve(Response.json({ error: "the sink answered 503" }, { status: 400 }));
    handler = await broker({
      issuer: ISSUER, secret: "s".repeat(40), fetcher: down, askDoor: () => Promise.resolve(true),
      providers: [{ name: "google", label: "Google", authUrl: `${G}/auth`, tokenUrl: `${G}/token`, issuers: ["https://accounts.google.com"], keys: async () => googleJwk, clientId: "op-client", door: "http://airlock:9998/door/google" }],
    });
    const failed = await signIn(A, "alice");
    assertEquals([failed.landed!.searchParams.get("error"), failed.landed!.searchParams.has("code")], ["access_denied", false]);
  } finally {
    await fake.shutdown();
  }
});

Deno.test("the door's startup consistency: a secret and a door need the flag, the flag needs both", () => {
  const e = (o: Record<string, string>) => (k: string) => o[k];
  const base = { GOOGLE_CLIENT_ID: "c" };
  const fails = (o: Record<string, string>) => { try { google(e({ ...base, ...o })); return false; } catch { return true; } };
  assertEquals(fails({ GOOGLE_CLIENT_SECRET: "s", GOOGLE_DOOR: "http://d" }), true, "door and secret, no flag");
  assertEquals(fails({ GOOGLE_DOOR: "http://d", GOOGLE_DOOR_ASKED: "1" }), true, "the flag needs the secret too");
  assertEquals(fails({ GOOGLE_CLIENT_SECRET: "s", GOOGLE_DOOR_ASKED: "1" }), true, "the flag needs the door");
  assertEquals(google(e({ ...base, GOOGLE_DOOR: "http://d/" }))?.door, "http://d/door/google");
  assertEquals(fails({ GOOGLE_CLIENT_SECRET: "s", GOOGLE_DOOR: "http://d", GOOGLE_DOOR_ASKED: "1" }), true, "the flag needs its tenants");
  assertEquals(fails({ GOOGLE_DOOR: "http://d", GOOGLE_DOOR_TENANTS: "https://a" }), true, "tenants need the flag");
  assertEquals(google(e({ ...base, GOOGLE_DOOR: "http://d", GOOGLE_CLIENT_SECRET: "s", GOOGLE_DOOR_ASKED: "1", GOOGLE_DOOR_TENANTS: "https://a, http://localhost:*" }))?.doorTenants, ["https://a", "http://localhost:*"]);
  assertEquals(google(e({ ...base, GOOGLE_CLIENT_SECRET: "s" }))?.door, undefined, "no door unless set");
  assertEquals(google(e(base)), null, "neither a secret nor a door: no Google");
});

Deno.test("the tenant's flag is asked at its own origin as the tenant, and an answer that does not come is off", async () => {
  const seen: { url: string; body: unknown }[] = [];
  const on = askedFlag("signin_door", (url, init) => { seen.push({ url: String(url), body: JSON.parse(String(init!.body)) }); return Promise.resolve(Response.json({ value: true })); });
  assertEquals(await on(A), true);
  assertEquals(seen, [{ url: `${A}/ofrep/v1/evaluate/flags/signin_door`, body: { context: { targetingKey: A } } }]);
  assertEquals(await askedFlag("signin_door", () => Promise.resolve(Response.json({ value: false })))(A), false);
  const fails = async (f: () => Promise<boolean>) => { try { await f(); return false; } catch { return true; } };
  assertEquals(await fails(() => askedFlag("signin_door", () => Promise.resolve(new Response("", { status: 404 })))(A)), true, "a flag not there is no answer");
  assertEquals(await fails(() => askedFlag("signin_door", () => Promise.reject(new Error("down")))(A)), true, "unreachable is no answer");
});
