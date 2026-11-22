// The broker's Facebook sign-in (identity/broker/facebook.ts, PRONTO-449) end to end, against a stand-in for Meta this module serves
// (its token endpoint and Graph's /me, checking the secret, the PKCE verifier and the app-secret proof as Meta does) and a stand-in for the
// tenant's flag: measured by what Meta was asked, what the tenant's ID token says, and what a refused sign-in answered.
import { fromBase64url, randomToken, sha256url } from '../../identity/oidc.ts';
import { broker } from '../../identity/broker/main.ts';
import { appSecretProof, facebook, facebookConfig, FACEBOOK } from '../../identity/broker/facebook.ts';

const TENANT = 'https://app.example.com';
const APP_ID = '1234567890123';
const SECRET = 'ab'.repeat(16);
const claimsOf = (jwt) => JSON.parse(new TextDecoder().decode(fromBase64url(jwt.split('.')[1])));
const linkOf = (html, path) => new URL([...html.matchAll(/href="([^"]+)"/g)].map((m) => m[1].replaceAll('&#38;', '&')).find((h) => h.includes(path)));

const ENV = { FACEBOOK_APP_ID: APP_ID, FACEBOOK_APP_SECRET: SECRET, FACEBOOK_TENANTS: TENANT };

/** facebookConfig for these settings: what it makes, or what it refused to. */
export function settings(over = {}) {
  const env = { ...ENV, ...over };
  try {
    const cfg = facebookConfig((k) => env[k] ?? undefined);
    return cfg === null ? { none: true } : { appId: cfg.appId, tenants: cfg.tenants, dialog: cfg.dialog, token: cfg.token, me: cfg.me };
  } catch (e) {
    return { refused: e.message };
  }
}

/** Graph's /me failing at the network level with an error that names the URL (as Deno's does): what the tenant is told, and whether the token went to the log. */
export async function meUnreachable() {
  const logged = [];
  const real = console.error;
  console.error = (...a) => { logged.push(a.map(String).join(' ')); };
  try {
    const cfg = facebookConfig((k) => ({ ...ENV })[k] ?? undefined);
    const provider = facebook(cfg, () => Promise.reject(new TypeError('fetch failed', { cause: new Error('error sending request for url (https://graph.facebook.com/v24.0/me?access_token=LEAKME)') })));
    let refused = null;
    try { await provider.claims(Response.json({ access_token: 'LEAKME' }), { profile: false, pn: 'x' }); } catch (e) { refused = e.constructor.name; }
    return { refused, leaked: logged.join(' ').includes('LEAKME') || String(refused).includes('LEAKME') };
  } finally { console.error = real; }
}

/** The settings with every variable unset. */
export const unset = () => settings({ FACEBOOK_APP_ID: '', FACEBOOK_APP_SECRET: '', FACEBOOK_TENANTS: '' });

/** The proof Meta asks of /me, for a token under the secret: its length and that it differs for another token. */
export async function proof() {
  const a = await appSecretProof('AT1', SECRET), b = await appSecretProof('AT2', SECRET);
  return { length: a.length, hex: /^[0-9a-f]{64}$/.test(a), differs: a !== b };
}

/**
 * The production broker signing a person in with Facebook for `tenant`:
 *  - `flag`: what the tenant's flag answers ('on', 'off', 'down' for a flagd that cannot be reached, 'missing' for a flag it does not know);
 *  - `scope`: what the tenant asks (`openid profile` by default);
 *  - `ua`: the reader's browser;
 *  - `meta`: how Meta behaves: 'ok', 'denied' (the person declines), 'exchange500', 'me403', 'noId', 'noToken';
 *  - `tamper`: change the state the dialog gave before the callback; `replay`: the callback is made twice.
 * The answer holds what Meta was asked and what the tenant learns.
 */
export async function brokered(p = {}) {
  const { tenant = TENANT, flag = 'on', scope = 'openid profile', ua = null, meta = 'ok', tamper = false, replay = false, who = '1000000000001', name = 'Ana Souza' } = p;
  const seen = { dialog: null, exchange: null, me: null, tokenCalls: 0, meCalls: 0, challenge: null };
  const server = Deno.serve({ hostname: '127.0.0.1', port: 0, onListen() {} }, async (req) => {
    const url = new URL(req.url);
    if (url.pathname === '/token') {
      seen.tokenCalls++;
      const f = new URLSearchParams(await req.text());
      seen.exchange = { id: f.get('client_id'), secretOk: f.get('client_secret') === SECRET, codeOk: f.get('code') === 'F1', verifierOk: !!f.get('code_verifier') && (await sha256url(f.get('code_verifier'))) === seen.challenge, redirect: f.get('redirect_uri') };
      if (meta === 'exchange500') return new Response('boom', { status: 500 });
      if (!seen.exchange.secretOk || !seen.exchange.codeOk || !seen.exchange.verifierOk) return Response.json({ error: { message: 'bad exchange' } }, { status: 400 });
      return Response.json(meta === 'noToken' ? {} : { access_token: 'AT1', token_type: 'bearer' });
    }
    if (url.pathname === '/me') {
      seen.meCalls++;
      const q = url.searchParams;
      seen.me = { fields: q.get('fields'), proofOk: q.get('appsecret_proof') === (await appSecretProof('AT1', SECRET)), tokenOk: req.headers.get('authorization') === 'Bearer AT1', tokenInUrl: q.has('access_token') };
      if (meta === 'me403' || !seen.me.proofOk || !seen.me.tokenOk) return Response.json({ error: { code: 190 } }, { status: 403 });
      if (meta === 'noId') return Response.json({ name });
      const asks = (q.get('fields') ?? '').split(',');
      return Response.json({ id: who, ...(asks.includes('name') ? { name } : {}), ...(asks.some((x) => x.startsWith('picture')) ? { picture: { data: { url: 'https://scontent.example/p.jpg' } } } : {}), email: 'secret@example.com' });
    }
    return new Response('no', { status: 404 });
  });
  try {
    const issuer = 'https://id.example.com';
    const base = `http://127.0.0.1:${server.addr.port}`;
    const cfg = facebookConfig((k) => ({ ...ENV, FACEBOOK_TEST_ENDPOINTS: '1', FACEBOOK_DIALOG_URL: 'https://www.facebook.example/dialog/oauth', FACEBOOK_TOKEN_URL: `${base}/token`, FACEBOOK_ME_URL: `${base}/me`, FACEBOOK_TENANTS: `${TENANT},https://other.example.com` })[k] ?? undefined);
    const asked = [];
    const flagFetcher = (url) => {
      asked.push(String(url));
      if (flag === 'down') return Promise.reject(new Error('flagd down'));
      if (flag === 'missing') return Promise.resolve(Response.json({ errorCode: 'FLAG_NOT_FOUND' }, { status: 404 }));
      return Promise.resolve(Response.json({ value: flag === 'on' }));
    };
    const handle = await broker({ issuer, secret: 's'.repeat(40), providers: [facebook(cfg)], fetcher: flagFetcher });
    const verifier = randomToken(32);
    const callback = `${tenant}/auth/oidc/facebook/callback`;
    const q = new URLSearchParams({ client_id: tenant, provider: 'facebook', redirect_uri: callback, state: 'S1', response_type: 'code', scope, code_challenge: await sha256url(verifier), code_challenge_method: 'S256', nonce: 'N1' });
    const first = await handle(new Request(`${issuer}/authorize?${q}`, { headers: ua ? { 'user-agent': ua } : {} }));
    if (first.status === 302) return { refused: new URL(first.headers.get('location')).searchParams.get('error'), flagAsked: asked, metaCalls: seen.tokenCalls + seen.meCalls };
    const consent = await first.text();
    if (first.status !== 200) return { status: first.status, flagAsked: asked, metaCalls: seen.tokenCalls + seen.meCalls };
    const toMeta = new URL((await handle(new Request(linkOf(consent, '/authorize/continue')))).headers.get('location'));
    const dialog = toMeta.searchParams;
    seen.challenge = dialog.get('code_challenge');
    seen.dialog = {
      host: toMeta.host, scope: dialog.get('scope'), method: dialog.get('code_challenge_method'), challenge: !!dialog.get('code_challenge'), nonce: dialog.has('nonce'), prompt: dialog.has('prompt'), verifier: dialog.has('code_verifier'),
      redirect: dialog.get('redirect_uri'), client: dialog.get('client_id'), responseType: dialog.get('response_type'),
    };
    const state = tamper ? `${dialog.get('state').slice(0, -3)}AAA` : dialog.get('state');
    const cb = (qs) => handle(new Request(`${issuer}/callback/facebook?${qs}&state=${encodeURIComponent(state)}`));
    const arrived = await cb(meta === 'denied' ? 'error=access_denied&error_reason=user_denied' : 'code=F1');
    if (arrived.status === 400) return { status: 400, dialog: seen.dialog, metaCalls: seen.tokenCalls + seen.meCalls };
    const back = new URL(arrived.headers.get('location'));
    if (back.searchParams.get('error')) return { error: back.searchParams.get('error'), dialog: seen.dialog, exchange: seen.exchange, me: seen.me, metaCalls: seen.tokenCalls + seen.meCalls };
    let second = null;
    if (replay) second = new URL((await cb('code=F1')).headers.get('location')).searchParams.get('error');
    const form = new URLSearchParams({ grant_type: 'authorization_code', code: back.searchParams.get('code') ?? '', client_id: tenant, redirect_uri: callback, code_verifier: verifier });
    const { id_token } = await (await handle(new Request(`${issuer}/token`, { method: 'POST', body: form }))).json();
    const c = claimsOf(id_token);
    return {
      dialog: seen.dialog, exchange: seen.exchange, me: seen.me, flagAsked: asked, replayed: second, sub: c.sub, provider: c.idp ?? c.provider ?? null, claims: Object.keys(c).sort(),
      name: c.name ?? null, picture: c.picture ?? null, hasEmail: JSON.stringify(c).includes('secret@example.com') || 'email' in c, hasFacebookId: JSON.stringify(c).includes(who), aud: c.aud,
    };
  } finally {
    await server.shutdown();
  }
}

/** The facts the broker reads (facebook_spec.json), as the file holds them. */
export const specFile = () => ({ ...FACEBOOK });
