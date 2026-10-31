// What the billing broker and an app's billing service share, so that either
// runs from this directory alone, copied into an app: base64url, ES256 tokens
// and key sets, bounded reads, and the broker's plain pages.

const enc = new TextEncoder();

export function base64url(bytes: Uint8Array): string {
  let s = "";
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

export function fromBase64url(text: string): Uint8Array<ArrayBuffer> {
  const b64 = text.replace(/-/g, "+").replace(/_/g, "/") + "===".slice((text.length + 3) % 4);
  return Uint8Array.from(atob(b64), (c) => c.charCodeAt(0));
}

export const randomToken = (bytes = 32) => base64url(crypto.getRandomValues(new Uint8Array(bytes)));

export async function sha256url(text: string): Promise<string> {
  return base64url(new Uint8Array(await crypto.subtle.digest("SHA-256", enc.encode(text))));
}

export type Jwk = JsonWebKey & { kid?: string };
export type KeySource = (kid: string) => Promise<Jwk | undefined>;

export class Refused extends Error {}

/** An ES256 JWT over `claims`, its header naming `kid`. */
export async function signEs256(privateKey: CryptoKey, kid: string, claims: Record<string, unknown>): Promise<string> {
  const head = base64url(enc.encode(JSON.stringify({ alg: "ES256", kid, typ: "JWT" })));
  const body = base64url(enc.encode(JSON.stringify(claims)));
  const sig = new Uint8Array(await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, privateKey, enc.encode(`${head}.${body}`)));
  return `${head}.${body}.${base64url(sig)}`;
}

/** An https origin, bare (no path, query, fragment or credentials), or null. */
export function originOf(v: unknown): string | null {
  if (typeof v !== "string" || v.length > 255) return null;
  let url: URL;
  try {
    url = new URL(v);
  } catch {
    return null;
  }
  if (url.protocol !== "https:" || url.username || url.password) return null;
  return url.origin === v ? url.origin : null;
}

/** A body read no further than `max` bytes, or null past it. */
export async function readCapped(stream: ReadableStream<Uint8Array> | null, max: number, declared?: string | null): Promise<string | null> {
  if (declared && Number(declared) > max) {
    await stream?.cancel();
    return null;
  }
  if (!stream) return "";
  const chunks: Uint8Array[] = [];
  let size = 0;
  for await (const chunk of stream) {
    size += chunk.length;
    if (size > max) return null;
    chunks.push(chunk);
  }
  const all = new Uint8Array(size);
  let at = 0;
  for (const c of chunks) { all.set(c, at); at += c.length; }
  return new TextDecoder().decode(all);
}

export const json = (status: number, body: unknown) =>
  new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json", "cache-control": "no-store" } });

export const esc = (s: string) => s.replace(/[&<>"']/g, (c) => `&#${c.charCodeAt(0)};`);

const PAGE_CSP = "default-src 'none'; style-src 'unsafe-inline'; form-action 'none'; frame-ancestors 'none'; base-uri 'none'";
export function page(title: string, body: string, status = 200): Response {
  return new Response(`<!doctype html>
<html lang="en">
<head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>${esc(title)}</title>
<style>body{margin:0;min-height:100vh;display:grid;place-items:center;font:17px/1.5 system-ui,sans-serif;background:#fafaf7;color:#1d1b20}
main{max-width:28rem;padding:2rem 1.5rem}h1{font-size:1.5rem;margin:0 0 .75rem}.origin{font-weight:700;word-break:break-all}
code{font-size:.9em}@media (prefers-color-scheme:dark){body{background:#141316;color:#ece7ef}}</style></head>
<body><main>${body}</main></body></html>
`, { status, headers: { "content-type": "text/html; charset=utf-8", "content-security-policy": PAGE_CSP, "cache-control": "no-store", "referrer-policy": "no-referrer" } });
}
