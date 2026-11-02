// pronto-identity's installer (bin/pronto-identity) on a stand-in app in a folder of its own: what
// it says, and its exit, before it writes anything; and the brokers' sign-in end to end, against a
// stand-in Google this module signs for, measured by what the provider was asked and what the
// tenant's ID token says.
import { base64url, fromBase64url, randomToken, sha256url } from '../../identity/oidc.ts';
import { broker } from '../../identity/broker/main.ts';
import { front } from '../../identity/hydra/front.ts';
import { fakeGoogle } from '../../identity/hydra/fake.ts';
import { phoneConfig, phoneUpstream } from '../../identity/broker/phone.ts';

const bin = new URL('../../bin/pronto-identity', import.meta.url).pathname;

/** The installer's run on an app named `package shop`, with `args`; `signin` its identity_signin.cue
 * from an earlier run, where it has one. */
export async function installed(args = [], signin = null) {
  const dir = await Deno.makeTempDir({ prefix: 'pronto-identity-' });
  await Deno.writeTextFile(`${dir}/program.cue`, 'package shop\n');
  if (signin !== null) await Deno.writeTextFile(`${dir}/identity_signin.cue`, signin);
  const out = await new Deno.Command('sh', { args: [bin, dir, ...args], stdout: 'piped', stderr: 'piped' }).output();
  const files = [];
  for await (const e of Deno.readDir(dir)) files.push(e.name);
  const written = files.includes('identity_signin.cue') ? await Deno.readTextFile(`${dir}/identity_signin.cue`) : '';
  await Deno.remove(dir, { recursive: true });
  return { exit: out.code, said: new TextDecoder().decode(out.stderr), files: files.sort(), scope: /client: "origin", scope: "([a-z ]*)"/.exec(written)?.[1] ?? null, signin: written };
}

// A stand-in Google: one RSA key, and the claims each code it answers carries beside the nonce
// the broker sent.
const enc = new TextEncoder();
const googleKey = await crypto.subtle.generateKey(
  { name: 'RSASSA-PKCS1-v1_5', modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: 'SHA-256' }, true, ['sign', 'verify']);
const googleJwk = { ...(await crypto.subtle.exportKey('jwk', googleKey.publicKey)), kid: 'g1' };
const TENANT = 'https://app.example.com';
const CALLBACK = `${TENANT}/auth/oidc/google/callback`;

async function googleToken(claims, nonce) {
  const head = base64url(enc.encode(JSON.stringify({ alg: 'RS256', kid: 'g1' })));
  const now = Math.floor(Date.now() / 1000);
  const body = base64url(enc.encode(JSON.stringify({ iss: 'https://accounts.google.com', aud: 'op-client', sub: 'person-1', nonce, ...claims, iat: now, exp: now + 300 })));
  const sig = new Uint8Array(await crypto.subtle.sign('RSASSA-PKCS1-v1_5', googleKey.privateKey, enc.encode(`${head}.${body}`)));
  return `${head}.${body}.${base64url(sig)}`;
}
const google = (tokenUrl) => ({
  name: 'google', label: 'Google', authUrl: 'https://google.example/auth', tokenUrl, issuers: ['https://accounts.google.com'],
  keys: (kid) => Promise.resolve(kid === 'g1' ? googleJwk : undefined), clientId: 'op-client', clientSecret: 'op-secret',
});
const claimsOf = (jwt) => JSON.parse(new TextDecoder().decode(fromBase64url(jwt.split('.')[1])));
// What a tenant learns of the person: the claims beyond the protocol's own.
const learned = (c) => Object.fromEntries(Object.entries(c).filter(([k]) => ['name', 'picture', 'email', 'email_verified'].includes(k)));
const linkOf = (html, path) => new URL([...html.matchAll(/href="([^"]+)"/g)].map((m) => m[1].replaceAll('&#38;', '&')).find((h) => h.includes(path)));
const sayOf = (html) => /<p>You'll continue[^]*?<\/p>/.exec(html)?.[0].replace(/<[^>]+>/g, '') ?? '';

/** The production broker (broker/main.ts) signing a person in for a tenant asking `scope`, Google
 * answering `claims`: the scope Google was asked for, what the broker's page says, and what the
 * tenant's ID token tells it of the person. */
export async function brokered(scope, claims = {}) {
  const tokens = new Map();
  const server = Deno.serve({ hostname: '127.0.0.1', port: 0, onListen() {} }, async (req) => {
    const code = new URLSearchParams(await req.text()).get('code');
    return Response.json({ id_token: tokens.get(code) });
  });
  try {
    const issuer = 'https://id.example.com';
    const handle = await broker({ issuer, secret: 's'.repeat(40), providers: [google(`http://127.0.0.1:${server.addr.port}/token`)] });
    const verifier = randomToken(32);
    const q = new URLSearchParams({ client_id: TENANT, provider: 'google', redirect_uri: CALLBACK, state: 'S1', response_type: 'code', scope, code_challenge: await sha256url(verifier), code_challenge_method: 'S256', nonce: 'N1' });
    const page = await (await handle(new Request(`${issuer}/authorize?${q}`))).text();
    const toGoogle = new URL((await handle(new Request(linkOf(page, '/authorize/continue')))).headers.get('location'));
    tokens.set('G1', await googleToken(claims, toGoogle.searchParams.get('nonce')));
    const back = new URL((await handle(new Request(`${issuer}/callback/google?code=G1&state=${encodeURIComponent(toGoogle.searchParams.get('state'))}`))).headers.get('location'));
    const form = new URLSearchParams({ grant_type: 'authorization_code', code: back.searchParams.get('code') ?? '', client_id: TENANT, redirect_uri: CALLBACK, code_verifier: verifier });
    const { id_token } = await (await handle(new Request(`${issuer}/token`, { method: 'POST', body: form }))).json();
    const discovery = await (await handle(new Request(`${issuer}/.well-known/openid-configuration`))).json();
    return { asked: toGoogle.searchParams.get('scope'), says: sayOf(page), learned: learned(claimsOf(id_token)), scopes: discovery.scopes_supported };
  } finally {
    await server.shutdown();
  }
}

/** The local broker (hydra/front.ts) signing a person in for a tenant asking `scope`, Google
 * answering `claims`, over a stand-in for Hydra's admin API: the scope Google was asked for, what
 * the page says, the scope consent grants, the claims it puts in the ID token and the scope the
 * tenant's client is registered with. */
export async function hydraBrokered(scope, claims = {}) {
  const issuer = 'http://localhost:19000';
  const asked = scope.split(' ');
  let context = null, consented = null, registered = null, nonce = '';
  const fetcher = async (input, init = {}) => {
    const url = new URL(String(input));
    if (url.pathname === '/token') return Response.json({ id_token: await googleToken(claims, nonce) });
    const body = init.body ? JSON.parse(String(init.body)) : undefined;
    const method = init.method ?? 'GET';
    if (url.pathname.startsWith('/admin/clients')) {
      if (method === 'GET') return new Response('{}', { status: 404 });
      registered = body;
      return Response.json(body);
    }
    if (url.pathname === '/admin/oauth2/auth/requests/login') {
      return Response.json({ client: { client_id: TENANT }, request_url: `${issuer}/oauth2/auth?provider=google`, requested_scope: asked });
    }
    if (url.pathname === '/admin/oauth2/auth/requests/login/accept') { context = body.context; return Response.json({ redirect_to: `${issuer}/consent?consent_challenge=K1` }); }
    if (url.pathname === '/admin/oauth2/auth/requests/consent') return Response.json({ context, requested_scope: asked });
    if (url.pathname === '/admin/oauth2/auth/requests/consent/accept') { consented = body; return Response.json({ redirect_to: CALLBACK }); }
    if (url.pathname === '/oauth2/auth') return new Response(null, { status: 302, headers: { location: `${issuer}/login?login_challenge=C1` } });
    return new Response('not found', { status: 404 });
  };
  const handle = await front({ issuer, secret: 's'.repeat(40), providers: [google('http://google.example/token')], hydra: { public: 'http://hydra', admin: 'http://hydra' }, fetcher });
  await handle(new Request(`${issuer}/oauth2/auth?${new URLSearchParams({ client_id: TENANT, provider: 'google', redirect_uri: CALLBACK })}`));
  const page = await (await handle(new Request(`${issuer}/login?login_challenge=C1`))).text();
  const toGoogle = new URL((await handle(new Request(linkOf(page, '/login/continue')))).headers.get('location'));
  nonce = toGoogle.searchParams.get('nonce');
  await handle(new Request(`${issuer}/callback/google?code=G1&state=${encodeURIComponent(toGoogle.searchParams.get('state'))}`));
  await handle(new Request(`${issuer}/consent?consent_challenge=K1`));
  return { asked: toGoogle.searchParams.get('scope'), says: sayOf(page), granted: consented?.grant_scope, learned: learned(consented?.session?.id_token ?? {}), registered: registered?.scope };
}

/** The stand-in for Google (hydra/fake.ts) asked for `scope`, signing in `who`: what its ID token
 * says of the person. */
export async function fakeAnswers(scope, who = 'tester') {
  const out = await fakeSignsIn(scope, who);
  return out.learned;
}

/** The stand-in for Google asked for `scope`, approving `who` (one its page lists, or any other
 * the scenario names): the approval's status, the people its page lists, and what the ID token
 * says of the person. */
export async function fakeSignsIn(scope, who) {
  const fake = await fakeGoogle('http://localhost:19000');
  const at = (u, init) => fake.handle(new Request(u, init), new URL(u));
  const q = new URLSearchParams({ client_id: 'fake-google-client', redirect_uri: 'http://localhost:19000/callback/google', state: 'S1', nonce: 'N1', scope });
  const page = await (await at(`http://localhost:19000/fake/google/auth?${q}`)).text();
  const listed = [...page.matchAll(/Continue as ([^<]+)</g)].map((m) => m[1]);
  const approve = linkOf(page, 'who=tester');
  approve.searchParams.set('who', who);
  const res = await at(approve.toString());
  if (res.status !== 302) return { status: res.status, listed, learned: {} };
  const back = new URL(res.headers.get('location'));
  const form = new URLSearchParams({ code: back.searchParams.get('code'), client_id: 'fake-google-client', client_secret: 'fake-google-secret', redirect_uri: 'http://localhost:19000/callback/google' });
  const { id_token } = await (await at('http://localhost:19000/fake/google/token', { method: 'POST', body: form })).json();
  return { status: res.status, listed, learned: learned(claimsOf(id_token)) };
}

// The phone (broker/phone.ts): a stand-in for Firebase's signing key, and the settings a broker
// offering the phone is started with.
const firebaseKey = await crypto.subtle.generateKey(
  { name: 'RSASSA-PKCS1-v1_5', modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: 'SHA-256' }, true, ['sign', 'verify']);
const firebaseJwk = { ...(await crypto.subtle.exportKey('jwk', firebaseKey.publicKey)), kid: 'f1' };
const PHONE_ENV = {
  PHONE_PROJECT: 'brawl-chess', PHONE_API_KEY: 'AIza-public', PHONE_APP_ID: '1:1:web:1',
  PHONE_ADMIT: 'https://app.example.com/rental/phone/admit', PHONE_TENANTS: 'https://app.example.com,https://localhost:*',
};

/** A Firebase ID token for a phone sign-in on `project`, as Firebase signs it (RS256, its key `f1`),
 * `over` replacing or adding claims; `unsigned` makes it the emulator's (alg none). */
async function firebaseToken(over = {}, unsigned = false, project = 'brawl-chess') {
  const now = Math.floor(Date.now() / 1000);
  const claims = { iss: `https://securetoken.google.com/${project}`, aud: project, sub: 'fb-uid-1', auth_time: now, iat: now, exp: now + 3600, phone_number: '+5511912345678', firebase: { sign_in_provider: 'phone' }, ...over };
  const body = base64url(enc.encode(JSON.stringify(claims)));
  if (unsigned) return `${base64url(enc.encode(JSON.stringify({ alg: 'none', typ: 'JWT' })))}.${body}.`;
  const head = base64url(enc.encode(JSON.stringify({ alg: 'RS256', kid: 'f1' })));
  const sig = new Uint8Array(await crypto.subtle.sign('RSASSA-PKCS1-v1_5', firebaseKey.privateKey, enc.encode(`${head}.${body}`)));
  return `${head}.${body}.${base64url(sig)}`;
}

/** The phone's settings from an environment (`over` on PHONE_ENV, a null value removing one), for a
 * broker at `issuer`: what phoneConfig makes of them. */
export function phoneSettings(over = {}, issuer = 'https://id.example.com') {
  const env = { ...PHONE_ENV, ...over };
  return phoneConfig((k) => env[k] ?? undefined, issuer);
}

/** The production broker (broker/main.ts) signing a person in by phone for `tenant`, Firebase's
 * token made with `over` (`unsigned` for the emulator's): the phone page's language, title, CSP and
 * whether it names a number; the page's answer to the token; and what the tenant's ID token says,
 * with whether its subject is the Firebase user's. `env` changes the broker's phone settings. */
export async function phoneBrokered(p = {}) {
  const { tenant = TENANT, over = {}, unsigned = false, lang = 'pt-BR,pt;q=0.9', env = {}, issuer = 'https://id.example.com', project = 'brawl-chess' } = p;
  const cfg = phoneSettings(env, issuer);
  const phone = await phoneUpstream(issuer, cfg, { keys: (kid) => Promise.resolve(kid === 'f1' ? firebaseJwk : undefined) });
  const handle = await broker({ issuer, secret: 's'.repeat(40), providers: [phone.provider], extra: phone.handle });
  const callback = `${tenant}/auth/oidc/phone/callback`;
  const verifier = randomToken(32);
  const q = new URLSearchParams({ client_id: tenant, provider: 'phone', redirect_uri: callback, state: 'S1', response_type: 'code', scope: 'openid profile', code_challenge: await sha256url(verifier), code_challenge_method: 'S256', nonce: 'N1' });
  const first = await handle(new Request(`${issuer}/authorize?${q}`));
  if (first.status === 302) return { refused: new URL(first.headers.get('location')).searchParams.get('error') };
  const consent = await first.text();
  const toPhone = new URL((await handle(new Request(linkOf(consent, '/authorize/continue')))).headers.get('location'));
  const pageRes = await handle(new Request(toPhone, { headers: { 'accept-language': lang } }));
  const page = await pageRes.text();
  const config = JSON.parse(/<script type="application\/json" id="phone-config">([^<]*)<\/script>/.exec(page)[1]);
  const approved = await handle(new Request(`${issuer}/phone/approve`, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ id: config.id, token: await firebaseToken(over, unsigned, project) }) }));
  const answer = await approved.json();
  const out = {
    says: sayOf(consent), lang: /<html lang="([^"]+)"/.exec(page)[1], title: config.strings.title, csp: pageRes.headers.get('content-security-policy'),
    asks: /id="phone-number"/.test(page) && /data-e164/.test(page), admit: config.admit, emulator: config.emulator, approved: approved.status, error: answer.error ?? null,
  };
  if (!answer.to) return out;
  const back = new URL((await handle(new Request(answer.to))).headers.get('location'));
  const form = new URLSearchParams({ grant_type: 'authorization_code', code: back.searchParams.get('code') ?? '', client_id: tenant, redirect_uri: callback, code_verifier: verifier });
  const { id_token } = await (await handle(new Request(`${issuer}/token`, { method: 'POST', body: form }))).json();
  const c = claimsOf(id_token);
  return { ...out, provider: c.provider ?? c.idp ?? null, sub: c.sub, firebaseSub: c.sub === 'fb-uid-1', aud: c.aud, claims: Object.keys(c).sort(), hasNumber: JSON.stringify(c).includes('912345678') };
}

/** The local broker on Hydra (hydra/front.ts) asked to sign `tenant` in by phone: how Hydra's login
 * is answered (accepted, or rejected with its error). */
export async function hydraPhoneLogin(tenant) {
  const issuer = 'http://localhost:19000';
  let rejected = null;
  const fetcher = (input, init = {}) => Promise.resolve((() => {
    const url = new URL(String(input));
    if (url.pathname === '/admin/oauth2/auth/requests/login') {
      return Response.json({ client: { client_id: tenant }, request_url: `${issuer}/oauth2/auth?provider=phone`, requested_scope: ['openid'] });
    }
    if (url.pathname === '/admin/oauth2/auth/requests/login/reject') { rejected = JSON.parse(String(init.body)).error; return Response.json({ redirect_to: `${tenant}/auth/oidc/phone/callback?error=${rejected}` }); }
    return new Response('not found', { status: 404 });
  })());
  const cfg = phoneSettings({}, issuer);
  const phone = await phoneUpstream(issuer, cfg);
  const handle = await front({ issuer, secret: 's'.repeat(40), providers: [phone.provider], hydra: { public: 'http://hydra', admin: 'http://hydra' }, fetcher, extra: phone.handle });
  const res = await handle(new Request(`${issuer}/login?login_challenge=C1`));
  return { status: res.status, rejected };
}
