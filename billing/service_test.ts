// The service hands the author's grants to the database: the release's set, or
// the flag billing_grants as flagd serves it now; each set once, and none taken
// away because flagd could not be asked.
import { service } from "./service.ts";

const eq = (a: unknown, b: unknown, m: string) => { if (JSON.stringify(a) !== JSON.stringify(b)) throw new Error(`${m}: expected ${JSON.stringify(b)}, got ${JSON.stringify(a)}`); };
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
