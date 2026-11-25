// What appstore_test.ts signs with: a certificate chain of its own, built with openssl, shaped as Apple's is (a root, an
// intermediate carrying Apple's intermediate extension, a leaf carrying Apple's leaf extension), and payloads shaped as Apple's
// are (JWSTransactionDecodedPayload, App Store Server Notifications v2, the Server API's subscription status). No Apple key,
// certificate or account is involved: nothing here is real, so nothing signed here is believed by a broker pinned to Apple's root.
import { base64url } from "../shared.ts";

const enc = new TextEncoder();

async function openssl(dir: string, ...args: string[]): Promise<void> {
  const out = await new Deno.Command("openssl", { args, cwd: dir, stdout: "null", stderr: "piped" }).output();
  if (!out.success) throw new Error(`openssl ${args.join(" ")}: ${new TextDecoder().decode(out.stderr)}`);
}

const b64 = (pem: string) => pem.replace(/-----[A-Z ]+-----|\s/g, "");

export interface Chain {
  rootPem: string;
  /** A JWS over `payload`, signed by the leaf, its x5c the chain. */
  sign(payload: Record<string, unknown>, header?: Record<string, unknown>): Promise<string>;
}

/** A chain: valid for `days` from now, with or without Apple's two extensions. */
export async function makeChain(o: { days?: number; leafExtension?: boolean; intermediateExtension?: boolean; leafIsCa?: boolean } = {}): Promise<Chain> {
  const dir = await Deno.makeTempDir({ prefix: "appstore-fixture-" });
  try {
    const days = String(o.days ?? 30);
    await openssl(dir, "ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", "root.key");
    await openssl(dir, "req", "-x509", "-new", "-key", "root.key", "-subj", "/CN=Test Root CA", "-days", days, "-out", "root.pem", "-addext", "basicConstraints=critical,CA:TRUE");
    for (const [name, serial, ca, oid] of [
      ["inter", "2", "CA:TRUE", o.intermediateExtension === false ? "" : "\n1.2.840.113635.100.6.2.1=ASN1:NULL"],
      ["leaf", "3", o.leafIsCa ? "CA:TRUE" : "CA:FALSE", o.leafExtension === false ? "" : "\n1.2.840.113635.100.6.11.1=ASN1:NULL"],
    ]) {
      await openssl(dir, "ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", `${name}.key`);
      await openssl(dir, "req", "-new", "-key", `${name}.key`, "-subj", `/CN=Test ${name}`, "-out", `${name}.csr`);
      await Deno.writeTextFile(`${dir}/${name}.ext`, `basicConstraints=${ca}${oid}\n`);
      const issuer = name === "inter" ? "root" : "inter";
      await openssl(dir, "x509", "-req", "-in", `${name}.csr`, "-CA", `${issuer}.pem`, "-CAkey", `${issuer}.key`, "-set_serial", serial, "-days", days, "-extfile", `${name}.ext`, "-out", `${name}.pem`);
    }
    await openssl(dir, "pkcs8", "-topk8", "-nocrypt", "-in", "leaf.key", "-outform", "DER", "-out", "leaf.p8");
    const [rootPem, inter, leaf, p8] = await Promise.all([
      Deno.readTextFile(`${dir}/root.pem`), Deno.readTextFile(`${dir}/inter.pem`), Deno.readTextFile(`${dir}/leaf.pem`), Deno.readFile(`${dir}/leaf.p8`),
    ]);
    const key = await crypto.subtle.importKey("pkcs8", p8, { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
    const x5c = [b64(leaf), b64(inter), b64(rootPem)];
    return {
      rootPem,
      async sign(payload, header = {}) {
        const head = base64url(enc.encode(JSON.stringify({ alg: "ES256", x5c, ...header })));
        const body = base64url(enc.encode(JSON.stringify(payload)));
        const sig = new Uint8Array(await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key, enc.encode(`${head}.${body}`)));
        return `${head}.${body}.${base64url(sig)}`;
      },
    };
  } finally {
    await Deno.remove(dir, { recursive: true });
  }
}

/** A P-256 key as the App Store Connect .p8 holds it (PKCS8 PEM): the Server API key the broker signs its calls with. */
export async function apiKeyPem(): Promise<string> {
  const pair = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]);
  const der = new Uint8Array(await crypto.subtle.exportKey("pkcs8", pair.privateKey));
  let s = "";
  for (const b of der) s += String.fromCharCode(b);
  return `-----BEGIN PRIVATE KEY-----\n${btoa(s).replace(/(.{64})/g, "$1\n")}\n-----END PRIVATE KEY-----\n`;
}

/** JWSTransactionDecodedPayload, with the fields the broker reads and a few Apple adds. */
export function transaction(o: {
  transactionId: string; originalTransactionId?: string; productId?: string; bundleId?: string; environment?: string; appAccountToken?: string | null;
  expiresDate?: number; revocationDate?: number; revocationReason?: number;
}): Record<string, unknown> {
  const now = Date.now();
  return {
    transactionId: o.transactionId, originalTransactionId: o.originalTransactionId ?? o.transactionId, bundleId: o.bundleId ?? "com.example.chess",
    productId: o.productId ?? "com.example.chess.premium.monthly", type: "Auto-Renewable Subscription", environment: o.environment ?? "Production",
    purchaseDate: now - 60_000, expiresDate: o.expiresDate ?? now + 30 * 86_400_000, signedDate: now, quantity: 1, storefront: "BRA", inAppOwnershipType: "PURCHASED",
    ...(o.appAccountToken === null ? {} : { appAccountToken: o.appAccountToken }),
    ...(o.revocationDate ? { revocationDate: o.revocationDate, revocationReason: o.revocationReason ?? 0 } : {}),
  };
}

/** An App Store Server Notifications v2 signedPayload's content. */
export function notification(o: { type: string; subtype?: string; uuid: string; signedTransactionInfo?: string; bundleId?: string; environment?: string }): Record<string, unknown> {
  return {
    notificationType: o.type, ...(o.subtype ? { subtype: o.subtype } : {}), notificationUUID: o.uuid, version: "2.0", signedDate: Date.now(),
    data: { bundleId: o.bundleId ?? "com.example.chess", environment: o.environment ?? "Production", ...(o.signedTransactionInfo ? { signedTransactionInfo: o.signedTransactionInfo } : {}) },
  };
}
