// The broker's isolation rules: a tenant is an https origin, its redirect is
// its own origin's one callback, a person's subject differs per tenant, and a
// code is redeemed once, by the tenant and redirect it was issued to.
import { MemoryStore } from "./store.ts";
import { callbackOf, Codes, type Grant, idTokenClaims, pairwiseKey, pairwiseSubject, parseAuthorize, sectorOf, sectorsOf, pkceMatches, redeem, tenantOf } from "./core.ts";
import { randomToken, Refused, sha256url, signEs256, verifyIdToken } from "../oidc.ts";

function assertEquals(a: unknown, b: unknown, m = "") {
  if (JSON.stringify(a) !== JSON.stringify(b)) throw new Error(`${m} expected ${JSON.stringify(b)}, got ${JSON.stringify(a)}`);
}

Deno.test("a tenant is a bare https origin, and nothing else", () => {
  assertEquals(tenantOf("https://app.example.com"), "https://app.example.com");
  assertEquals(tenantOf("https://localhost:28102"), "https://localhost:28102");
  for (const bad of ["http://localhost:28102", "https://app.example.com/", "https://app.example.com/app", "https://a@b.example",
    "https://App.Example.com", "https://x.example?y", "https://x.example#z", "app.example.com", "", null, 3]) {
    assertEquals(tenantOf(bad), null, String(bad));
  }
});

const providers = ["google"];
async function authorizeQuery(over: Record<string, string> = {}) {
  return new URLSearchParams({
    client_id: "https://app-a.example", redirect_uri: "https://app-a.example/auth/oidc/google/callback",
    response_type: "code", scope: "openid", state: "s1", nonce: "n1", provider: "google",
    code_challenge: await sha256url(randomToken(32)), code_challenge_method: "S256", ...over,
  });
}

Deno.test("a request is accepted only for the tenant's own callback for the provider it asks for", async () => {
  const ok = parseAuthorize(await authorizeQuery(), providers);
  assertEquals(ok.ok, true);
  for (const redirect_uri of [
    "https://app-b.example/auth/oidc/google/callback", // another tenant's
    "https://app-a.example/auth/oidc/github/callback", // another provider's
    "https://app-a.example/auth/identity/callback", // the wrapper's, before mecha signed in itself
    "https://app-a.example/auth/oidc/google/callback?x=1",
    "https://app-a.example/elsewhere",
    "https://evil.example/auth/oidc/google/callback",
  ]) {
    const r = parseAuthorize(await authorizeQuery({ redirect_uri }), providers);
    assertEquals(r.ok === false && r.redirect === null, true, redirect_uri);
  }
});

Deno.test("an error is sent to the redirect only once the redirect is the tenant's", async () => {
  // A provider the broker does not offer names no callback it could trust.
  const bad = parseAuthorize(await authorizeQuery({ provider: "myspace", redirect_uri: "https://app-a.example/auth/oidc/myspace/callback" }), providers);
  assertEquals(bad.ok === false && bad.redirect, null);
  const noState = parseAuthorize(await authorizeQuery({ state: "" }), providers);
  assertEquals(noState.ok === false && noState.redirect, null);
  const noPkce = parseAuthorize(await authorizeQuery({ code_challenge_method: "plain" }), providers);
  assertEquals(noPkce, { ok: false, error: "invalid_request", redirect: "https://app-a.example/auth/oidc/google/callback" });
  const notOpenid = parseAuthorize(await authorizeQuery({ scope: "email" }), providers);
  assertEquals(notOpenid.ok === false && notOpenid.error, "invalid_scope");
});

Deno.test("one person has unrelated subjects in two tenants, and per provider", async () => {
  const key = await pairwiseKey("x".repeat(32));
  const a = await pairwiseSubject(key, "https://app-a.example", "google", "g-123");
  const b = await pairwiseSubject(key, "https://app-b.example", "google", "g-123");
  const again = await pairwiseSubject(key, "https://app-a.example", "google", "g-123");
  const other = await pairwiseSubject(key, "https://app-a.example", "github", "g-123");
  assertEquals(a === b, false);
  assertEquals(a === again, true);
  assertEquals(a === other, false);
  const rotated = await pairwiseSubject(await pairwiseKey("y".repeat(32)), "https://app-a.example", "google", "g-123");
  assertEquals(a === rotated, false);
});

const grant = (over: Partial<Grant> = {}): Grant => ({
  tenant: "https://app-a.example", redirectUri: callbackOf("https://app-a.example", "google"), challenge: "", nonce: "n1", sub: "p-1", provider: "google", ...over,
});

Deno.test("a code is redeemed once, by its tenant and redirect, with its verifier", async () => {
  const verifier = randomToken(32);
  const challenge = await sha256url(verifier);
  const codes = new Codes();
  const form = (code: string, over: Record<string, string> = {}) => new URLSearchParams({
    grant_type: "authorization_code", code, client_id: "https://app-a.example",
    redirect_uri: "https://app-a.example/auth/oidc/google/callback", code_verifier: verifier, ...over,
  });
  const c1 = await codes.issue(grant({ challenge }));
  assertEquals((await redeem(codes, form(c1))).ok, true);
  assertEquals(await redeem(codes, form(c1)), { ok: false, error: "invalid_grant" }); // single use
  const tampered: Record<string, string>[] = [
    { client_id: "https://app-b.example" }, // another tenant presenting A's code
    { redirect_uri: "https://app-b.example/auth/oidc/google/callback" },
    { code_verifier: randomToken(32) },
    { grant_type: "password" },
  ];
  for (const over of tampered) {
    const c = await codes.issue(grant({ challenge }));
    assertEquals((await redeem(codes, form(c, over))).ok, false, JSON.stringify(over));
  }
});

Deno.test("a code expires", async () => {
  let t = 0;
  const codes = new Codes(new MemoryStore(() => t), 1000);
  const c = await codes.issue(grant());
  t = 1000;
  assertEquals(await codes.take(c), null);
});

Deno.test("PKCE accepts only the verifier of the challenge", async () => {
  const v = randomToken(32);
  assertEquals(await pkceMatches(v, await sha256url(v)), true);
  assertEquals(await pkceMatches(v + "x", await sha256url(v)), false);
  assertEquals(await pkceMatches("short", await sha256url("short")), false);
});

Deno.test("the ID token is the tenant's alone: another tenant refuses it", async () => {
  const pair = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]);
  const jwk = { ...(await crypto.subtle.exportKey("jwk", pair.publicKey)), kid: "b1" };
  const keys = async (kid: string) => (kid === "b1" ? jwk : undefined);
  const now = 1_800_000_000;
  const token = await signEs256(pair.privateKey, "b1", idTokenClaims({ issuer: "https://id.example", grant: grant(), now }));
  const check = (audience: string) => verifyIdToken(token, { alg: "ES256", issuers: ["https://id.example"], audience, nonce: "n1", keys, now });
  assertEquals((await check("https://app-a.example")).sub, "p-1");
  let refused = "";
  try { await check("https://app-b.example"); } catch (e) { refused = e instanceof Refused ? e.message : String(e); }
  assertEquals(refused, "id token audience");
});

Deno.test("a moved tenant's sector is read from BROKER_SECTORS, and a malformed one refuses to start", () => {
  const sectors = sectorsOf(" https://new.example=https://old.example , https://b2.example=https://b.example");
  assertEquals(sectorOf(sectors, "https://new.example"), "https://old.example");
  assertEquals(sectorOf(sectors, "https://b2.example"), "https://b.example");
  assertEquals(sectorOf(sectors, "https://other.example"), "https://other.example", "an unmapped tenant is its own sector");
  assertEquals(sectorsOf(undefined).size, 0);
  assertEquals(sectorsOf("").size, 0);
  for (const bad of [
    "https://new.example", "https://new.example=http://old.example", "https://new.example/=https://old.example",
    "https://new.example=https://old.example=https://x.example", "https://a.example=https://a.example",
    "https://a.example=https://b.example,https://a.example=https://c.example",
    "https://a.example=https://b.example,https://b.example=https://c.example",
  ]) {
    let threw = false;
    try { sectorsOf(bad); } catch { threw = true; }
    assertEquals(threw, true, bad);
  }
});

Deno.test("the Hydra front's pages are /oauth2/auth and /login: a crawler is refused the first, /authorize is no page of it", async () => {
  const h = observed(async () => new Response("ok"), () => {}, ["/login", "/oauth2/auth"]);
  const ua = { "user-agent": "Mozilla/5.0 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)" };
  let r = await h(new Request("https://id.example/oauth2/auth?client_id=https%3A%2F%2Fa.example", { headers: ua }));
  assertEquals([r.status, r.headers.get("x-robots-tag")], [403, "noindex, nofollow"]);
  r = await h(new Request("https://id.example/oauth2/auth?client_id=https%3A%2F%2Fa.example"));
  assertEquals([r.status, r.headers.get("x-robots-tag")], [200, "noindex, nofollow"]);
  r = await h(new Request("https://id.example/authorize", { headers: ua }));
  assertEquals([r.status, r.headers.get("x-robots-tag")], [200, null]);
});

import { crawlerOf, observed } from "./core.ts";

Deno.test("a known crawler is told from a person, and a phone brand that ends in bot is no crawler", () => {
  for (const ua of [
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15 (Applebot/0.1; +http://www.apple.com/go/applebot)",
    "Mozilla/5.0 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)", "facebookexternalhit/1.1", "WhatsApp/2.23 A", "Slackbot-LinkExpanding 1.0",
  ]) assertEquals(crawlerOf(ua), true, ua);
  for (const ua of [
    "Mozilla/5.0 (Linux; Android 13; Cubot P60) AppleWebKit/537.36 Chrome/120 Mobile Safari/537.36",
    "Mozilla/5.0 (iPhone; CPU iPhone OS 17_4 like Mac OS X) AppleWebKit/605.1.15 Version/17.4 Mobile/15E148 Safari/604.1",
    // The scenarios and the flip cases drive a headless Chrome: it is a person to the broker.
    "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) HeadlessChrome/120.0.0.0 Safari/537.36", "", null, undefined,
  ]) assertEquals(crawlerOf(ua), false, String(ua));
});

Deno.test("the sign-in pages are noindex, a crawler is refused them, and each request is one line without query or agent", async () => {
  const lines: string[] = [];
  let served = 0;
  const h = observed(async (req) => {
    served++;
    return new Response(new URL(req.url).pathname === "/authorize" ? "<html>Continue</html>" : "ok", { status: 200, headers: { "content-type": "text/html" } });
  }, (l) => lines.push(l));
  const human = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_4 like Mac OS X) AppleWebKit/605.1.15 Version/17.4 Mobile/15E148 Safari/604.1";
  const bot = "Mozilla/5.0 (Macintosh) AppleWebKit/605.1.15 Version/17.4 Safari/605.1.15 (Applebot/0.1; +http://www.apple.com/go/applebot)";
  const q = "?client_id=https%3A%2F%2Fbonkchess.com&state=SECRET&code_challenge=SECRET";
  let r = await h(new Request(`https://id.example/authorize${q}`, { headers: { "user-agent": human } }));
  assertEquals([r.status, r.headers.get("x-robots-tag"), await r.text()], [200, "noindex, nofollow", "<html>Continue</html>"]);
  r = await h(new Request(`https://id.example/authorize${q}`, { headers: { "user-agent": bot } }));
  assertEquals([r.status, r.headers.get("x-robots-tag"), (await r.text()).includes("Continue")], [403, "noindex, nofollow", false]);
  assertEquals(served, 1, "the crawler never reached the handler");
  r = await h(new Request("https://id.example/login?login_challenge=SECRET", { headers: { "user-agent": bot } }));
  assertEquals([r.status, r.headers.get("x-robots-tag")], [403, "noindex, nofollow"]);
  r = await h(new Request("https://id.example/jwks", { headers: { "user-agent": bot } }));
  assertEquals([r.status, r.headers.get("x-robots-tag")], [200, null]);
  assertEquals(lines, [
    "broker: GET /authorize 200 human bonkchess.com", "broker: GET /authorize 403 bot bonkchess.com",
    "broker: GET /login 403 bot -", "broker: GET /jwks 200 bot -",
  ]);
  for (const l of lines) if (/SECRET|Mozilla|Applebot/.test(l)) throw new Error(`line leaks: ${l}`);
});
