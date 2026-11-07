// WebAuthn's two forms, for a host that offers passkeys through one bridge: the options a page passes
// navigator.credentials (ArrayBuffers and views) as the JSON the host takes (base64url strings), and
// the host's answer as the PublicKeyCredential the page expects. Pure: browser.js wires it to the bridge.

const ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";

/** The bytes of a BufferSource (an ArrayBuffer or a view on one). */
export function bytesOf(source) {
  if (source instanceof ArrayBuffer) return new Uint8Array(source);
  if (ArrayBuffer.isView(source)) return new Uint8Array(source.buffer, source.byteOffset, source.byteLength);
  throw new TypeError("not a BufferSource");
}

/** Base64url of bytes, unpadded. */
export function b64u(source) {
  const b = bytesOf(source);
  let out = "";
  for (let i = 0; i < b.length; i += 3) {
    const n = (b[i] << 16) | ((b[i + 1] ?? 0) << 8) | (b[i + 2] ?? 0);
    out += ALPHABET[(n >> 18) & 63] + ALPHABET[(n >> 12) & 63];
    if (i + 1 < b.length) out += ALPHABET[(n >> 6) & 63];
    if (i + 2 < b.length) out += ALPHABET[n & 63];
  }
  return out;
}

/** The ArrayBuffer a base64url text (padded or not, or plain base64) is. */
export function unb64u(text) {
  const clean = String(text).replace(/=+$/, "").replace(/\+/g, "-").replace(/\//g, "_");
  if (/[^A-Za-z0-9_-]/.test(clean) || clean.length % 4 === 1) throw new TypeError("not base64url");
  const out = new Uint8Array(Math.floor((clean.length * 3) / 4));
  let o = 0;
  for (let i = 0; i < clean.length; i += 4) {
    let n = 0, k = 0;
    for (; k < 4 && i + k < clean.length; k++) n = (n << 6) | ALPHABET.indexOf(clean[i + k]);
    n <<= 6 * (4 - k);
    out[o++] = (n >> 16) & 255;
    if (k > 2) out[o++] = (n >> 8) & 255;
    if (k > 3) out[o++] = n & 255;
  }
  return out.buffer;
}

const descriptor = (c) => ({ ...c, id: b64u(c.id) });

/** The options a page passed (`publicKey`) as the JSON the host takes: each BufferSource a base64url string. */
export function optionsToJson(publicKey) {
  const o = { ...publicKey, challenge: b64u(publicKey.challenge) };
  if (publicKey.user) o.user = { ...publicKey.user, id: b64u(publicKey.user.id) };
  if (publicKey.excludeCredentials) o.excludeCredentials = publicKey.excludeCredentials.map(descriptor);
  if (publicKey.allowCredentials) o.allowCredentials = publicKey.allowCredentials.map(descriptor);
  return JSON.stringify(o);
}

/** The error a ceremony ends in, as a browser's DOMException is named. */
export class PasskeyError extends Error {
  constructor(message, name) { super(message); this.name = name; this.code = 0; }
}

/** The PublicKeyCredential the host's answer (the JSON of a WebAuthn response, base64url throughout) is. */
export function credentialOf(json) {
  const r = typeof json === "string" ? JSON.parse(json) : json;
  const response = { clientDataJSON: unb64u(r.response.clientDataJSON) };
  if (r.response.attestationObject !== undefined) {
    response.attestationObject = unb64u(r.response.attestationObject);
    const transports = r.response.transports ?? [];
    response.getTransports = () => [...transports];
  } else {
    response.authenticatorData = unb64u(r.response.authenticatorData);
    response.signature = unb64u(r.response.signature);
    response.userHandle = r.response.userHandle ? unb64u(r.response.userHandle) : null;
  }
  const extensions = r.clientExtensionResults ?? {};
  return {
    id: r.id, rawId: unb64u(r.rawId), type: "public-key", response,
    authenticatorAttachment: r.authenticatorAttachment ?? null,
    getClientExtensionResults: () => ({ ...extensions }),
  };
}

/** The error the host's refusal ({name, message} as JSON) is. */
export function errorOf(json) {
  let r;
  try { r = typeof json === "string" ? JSON.parse(json) : json; } catch { r = {}; }
  return new PasskeyError(r?.message ?? "The operation either timed out or was not allowed.", r?.name ?? "NotAllowedError");
}

/** The platform's btoa: a binary string (each char one byte) as padded base64. */
export function btoaOf(binary) {
  const s = String(binary);
  const bytes = new Uint8Array(s.length);
  for (let i = 0; i < s.length; i++) {
    if (s.charCodeAt(i) > 255) throw new PasskeyError("The string to be encoded contains characters outside of the Latin1 range.", "InvalidCharacterError");
    bytes[i] = s.charCodeAt(i);
  }
  const text = b64u(bytes).replace(/-/g, "+").replace(/_/g, "/");
  return text + "=".repeat((4 - (text.length % 4)) % 4);
}

/** The platform's atob: base64 as a binary string. */
export function atobOf(text) {
  let bytes;
  try { bytes = new Uint8Array(unb64u(String(text).replace(/\s+/g, ""))); } catch { throw new PasskeyError("The string to be decoded is not correctly encoded.", "InvalidCharacterError"); }
  let out = "";
  for (let i = 0; i < bytes.length; i++) out += String.fromCharCode(bytes[i]);
  return out;
}
