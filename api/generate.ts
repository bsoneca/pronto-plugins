// pronto-api's generator (docs/pronto-api.md in pronto, PRONTO-313). From an app's api_spec.cue
// and program.cue, through api_plugin.cue's `apiContract`, it writes the app's contract:
//   api/v1/<package>.proto   the published contract, with google.api.http annotations
//   api/v1/routes.json       the REST route table the service serves (api/service.ts's Route[])
//   api/v1/fields.lock.cue   every field number ever assigned, append-only
//   api/v1/descriptor.binpb  `buf build` of the .proto, which the service loads at start
//   api/v1/openapi.json      REST documentation, from the same contract
// and `breaking` holds the descriptor set to the last released one (api/v1/released.binpb) with
// `buf breaking`, rule set WIRE_JSON. Nothing here names an app: what is exported is the app's.
//   generate.ts <app-dir>            write the contract
//   generate.ts breaking <app-dir>   buf breaking against released.binpb, when there is one
import { createFileRegistry, fromBinary } from "npm:@bufbuild/protobuf@2.10.1";
import { FileDescriptorSetSchema } from "npm:@bufbuild/protobuf@2.10.1/wkt";

export interface Field {
  name: string;
  type: string;
  repeated?: boolean;
}
export interface Message {
  name: string;
  fields: Field[];
}
export interface Method {
  name: string;
  input: string;
  output: string;
  http: { method: string; path: string; body?: string };
}
export interface Service {
  name: string;
  methods: Method[];
  messages: Message[];
}
export interface Contract {
  package: string;
  file: string;
  services: Service[];
  routes: { method: string; path: string; rpc: string }[];
}
/** Field numbers by message, then by field name: the live ones, and those of fields since removed. */
export interface Lock {
  fields: Record<string, Record<string, number>>;
  retired: Record<string, Record<string, number>>;
}

const here = new URL(".", import.meta.url).pathname;
const tool = (name: string) => Deno.env.get(name.toUpperCase()) ?? name;

async function run(cmd: string, args: string[], cwd?: string): Promise<{ ok: boolean; out: string }> {
  const r = await new Deno.Command(tool(cmd), { args, cwd, stdout: "piped", stderr: "piped" }).output();
  const dec = new TextDecoder();
  return { ok: r.success, out: (dec.decode(r.stdout) + dec.decode(r.stderr)).trim() };
}

async function cueJson(args: string[], cwd: string) {
  const r = await run("cue", ["export", ...args, "--out", "json"], cwd);
  if (!r.ok) throw new Error(`api: cue export ${args.join(" ")}: ${r.out}`);
  return JSON.parse(r.out);
}

const exists = (p: string) => Deno.stat(p).then(() => true, () => false);

/** The app's contract, as api_plugin.cue computes it from api_spec.cue and program.cue. */
export const contractOf = (app: string): Promise<Contract> => cueJson([".", "-e", "apiContract"], app);

/** The lock the app holds, empty when it has none yet. */
export async function lockOf(app: string): Promise<Lock> {
  const path = `${app}/api/v1/fields.lock.cue`;
  if (!(await exists(path))) return { fields: {}, retired: {} };
  const l = await cueJson([path], app);
  return { fields: l.fields ?? {}, retired: l.retired ?? {} };
}

/** Each message's field numbers in the released descriptor set, for the contract's package. */
export async function releasedOf(app: string, pkg: string): Promise<Record<string, Record<string, number>>> {
  const path = `${app}/api/v1/released.binpb`;
  if (!(await exists(path))) return {};
  const registry = createFileRegistry(fromBinary(FileDescriptorSetSchema, await Deno.readFile(path)));
  const out: Record<string, Record<string, number>> = {};
  for (const t of registry) {
    if (t.kind !== "message" || !t.typeName.startsWith(`${pkg}.`)) continue;
    out[t.name] = Object.fromEntries(t.fields.map((f) => [f.name, f.number]));
  }
  return out;
}

/** The lock after `contract`: a field keeps its number, a new field takes one above every number
 * its message ever had, and a removed field's number is kept as retired, never given again. Fails
 * on a lock that gives one number twice in a message (reused), or that numbers a released field
 * otherwise than the release did (renumbered) or lost it. */
export function numbered(contract: Contract, lock: Lock, released: Record<string, Record<string, number>>): Lock {
  const msgs = new Set([...Object.keys(lock.fields), ...Object.keys(lock.retired)]);
  for (const m of msgs) {
    const seen = new Map<number, string>();
    for (const [name, n] of [...Object.entries(lock.fields[m] ?? {}), ...Object.entries(lock.retired[m] ?? {})]) {
      if (!Number.isInteger(n) || n < 1) throw new Error(`api: ${m}.${name}: ${n} is not a field number`);
      if (seen.has(n)) throw new Error(`api: field number ${n} reused in ${m}: ${seen.get(n)} and ${name} (fields.lock.cue is append-only)`);
      seen.set(n, name);
    }
  }
  for (const [m, fields] of Object.entries(released)) {
    for (const [name, n] of Object.entries(fields)) {
      const held = lock.fields[m]?.[name] ?? lock.retired[m]?.[name];
      if (held === undefined) throw new Error(`api: ${m}.${name} was released as ${n} and fields.lock.cue lost it`);
      if (held !== n) throw new Error(`api: ${m}.${name} renumbered: released as ${n}, fields.lock.cue says ${held}`);
    }
  }
  const out: Lock = { fields: {}, retired: structuredClone(lock.retired) };
  const messages = contract.services.flatMap((s) => s.messages);
  for (const msg of messages) {
    const before = { ...lock.fields[msg.name] };
    const retired = out.retired[msg.name] ?? {};
    let top = Math.max(0, ...Object.values(before), ...Object.values(retired));
    const now: Record<string, number> = {};
    for (const f of msg.fields) {
      if (before[f.name] !== undefined) now[f.name] = before[f.name];
      else if (retired[f.name] !== undefined) {
        // The same name back: the same field, under the number it always had.
        now[f.name] = retired[f.name];
        delete retired[f.name];
      } else now[f.name] = ++top;
    }
    for (const [name, n] of Object.entries(before)) if (!(name in now)) retired[name] = n;
    out.fields[msg.name] = now;
    if (Object.keys(retired).length) out.retired[msg.name] = retired;
    else delete out.retired[msg.name];
  }
  // A message the contract no longer has keeps its numbers, all retired.
  for (const [m, fields] of Object.entries(lock.fields)) {
    if (messages.some((x) => x.name === m)) continue;
    out.retired[m] = { ...out.retired[m], ...fields };
  }
  return out;
}

const header = (from: string) => `generated by pronto-api from ${from} — do not edit`;

/** The .proto text of the contract, numbered by `lock`. */
export function protoOf(contract: Contract, lock: Lock): string {
  const types = new Set(contract.services.flatMap((s) => s.messages.flatMap((m) => m.fields.map((f) => f.type))));
  const imports = ["google/api/annotations.proto"];
  if (types.has("google.protobuf.Timestamp")) imports.push("google/protobuf/timestamp.proto");
  if (types.has("google.protobuf.Value")) imports.push("google/protobuf/struct.proto");
  const lines = [`// ${header("api_spec.cue and program.cue")}`, `syntax = "proto3";`, ``, `package ${contract.package};`, ``];
  for (const i of imports) lines.push(`import "${i}";`);
  for (const s of contract.services) {
    lines.push(``, `service ${s.name} {`);
    for (const m of s.methods) {
      const verb = m.http.method.toLowerCase();
      const body = m.http.body ? ` body: "${m.http.body}"` : "";
      lines.push(`  rpc ${m.name}(${m.input}) returns (${m.output}) {`, `    option (google.api.http) = { ${verb}: "${m.http.path}"${body} };`, `  }`);
    }
    lines.push(`}`);
    for (const msg of s.messages) {
      const retired = Object.values(lock.retired[msg.name] ?? {}).sort((a, b) => a - b);
      lines.push(``, `message ${msg.name} {`);
      for (const f of msg.fields) lines.push(`  ${f.repeated ? "repeated " : ""}${f.type} ${f.name} = ${lock.fields[msg.name][f.name]};`);
      // Retired numbers are kept out of reach without reserving them: a removed field stays a
      // breaking change, which `breaking` refuses against the release.
      if (retired.length) lines.push(`  // retired: ${retired.join(", ")} (fields.lock.cue)`);
      lines.push(`}`);
    }
  }
  return lines.join("\n") + "\n";
}

const camel = (s: string) => s.replace(/_([a-z0-9])/g, (_, c) => c.toUpperCase());
const schemaOf = (t: string): Record<string, unknown> => ({
  string: { type: "string" },
  bool: { type: "boolean" },
  int32: { type: "integer", format: "int32" },
  int64: { type: "string", format: "int64" },
  double: { type: "number", format: "double" },
  bytes: { type: "string", format: "byte" },
  "google.protobuf.Timestamp": { type: "string", format: "date-time" },
  "google.protobuf.Value": {},
}[t] ?? { $ref: `#/components/schemas/${t}` });

/** OpenAPI 3.1 for the REST routes: each route's path and query fields, its body and its answer. */
export function openapiOf(contract: Contract): Record<string, unknown> {
  const messages = Object.fromEntries(contract.services.flatMap((s) => s.messages).map((m) => [m.name, m]));
  const paths: Record<string, Record<string, unknown>> = {};
  for (const s of contract.services) {
    for (const m of s.methods) {
      const inPath = [...m.http.path.matchAll(/\{(\w+)\}/g)].map((x) => x[1]);
      const input = messages[m.input];
      const params = [
        ...inPath.map((name) => ({ name, in: "path", required: true, schema: schemaOf(input.fields.find((f) => f.name === name)!.type) })),
        ...(m.http.body
          ? []
          : input.fields.filter((f) => !inPath.includes(f.name)).map((f) => ({ name: camel(f.name), in: "query", schema: schemaOf(f.type) }))),
      ];
      paths[m.http.path] ??= {};
      paths[m.http.path][m.http.method.toLowerCase()] = {
        operationId: `${s.name}.${m.name}`,
        ...(params.length ? { parameters: params } : {}),
        ...(m.http.body ? { requestBody: { required: true, content: { "application/json": { schema: { $ref: `#/components/schemas/${m.input}` } } } } } : {}),
        responses: { "200": { description: "OK", content: { "application/json": { schema: { $ref: `#/components/schemas/${m.output}` } } } } },
      };
    }
  }
  const schemas = Object.fromEntries(
    Object.values(messages).map((m) => [m.name, {
      type: "object",
      properties: Object.fromEntries(m.fields.map((f) => [camel(f.name), f.repeated ? { type: "array", items: schemaOf(f.type) } : schemaOf(f.type)])),
    }]),
  );
  return { openapi: "3.1.0", info: { title: contract.package, version: contract.package.split(".").pop() }, paths, components: { schemas } };
}

const lockText = (lock: Lock) =>
  `// ${header("api_spec.cue and program.cue")}. Append-only: a field's number is never given again,\n` +
  `// and a removed field's stays under retired.\n` +
  `fields: ${JSON.stringify(lock.fields, null, "\t")}\n` + `retired: ${JSON.stringify(lock.retired, null, "\t")}\n`;

/** Writes the app's contract under api/v1/; fails, writing nothing, on a lock it cannot keep. */
export async function generate(app: string): Promise<{ proto: string; routes: Contract["routes"]; lock: Lock }> {
  const contract = await contractOf(app);
  const lock = numbered(contract, await lockOf(app), await releasedOf(app, contract.package));
  const proto = protoOf(contract, lock);
  // buf builds the .proto beside the google.api annotations the plugin keeps (api/proto/).
  const build = await Deno.makeTempDir();
  try {
    await Deno.writeTextFile(`${build}/${contract.file}`, proto);
    await Deno.mkdir(`${build}/google/api`, { recursive: true });
    for (const f of ["annotations.proto", "http.proto"]) await Deno.copyFile(`${here}proto/google/api/${f}`, `${build}/google/api/${f}`);
    const out = `${build}/descriptor.binpb`;
    const b = await run("buf", ["build", build, "-o", out]);
    if (!b.ok) throw new Error(`api: buf build: ${b.out}`);
    const dir = `${app}/api/v1`;
    await Deno.mkdir(dir, { recursive: true });
    await Deno.writeTextFile(`${dir}/${contract.file}`, proto);
    await Deno.writeTextFile(`${dir}/routes.json`, JSON.stringify(contract.routes, null, 2) + "\n");
    await Deno.writeTextFile(`${dir}/fields.lock.cue`, lockText(lock));
    await Deno.writeTextFile(`${dir}/openapi.json`, JSON.stringify(openapiOf(contract), null, 2) + "\n");
    await Deno.copyFile(out, `${dir}/descriptor.binpb`);
  } finally {
    await Deno.remove(build, { recursive: true });
  }
  return { proto, routes: contract.routes, lock };
}

/** `buf breaking` (WIRE_JSON) of the app's descriptor set against its last release; ok with no
 * release yet. */
export async function breaking(app: string): Promise<{ ok: boolean; out: string }> {
  const dir = `${app}/api/v1`;
  if (!(await exists(`${dir}/released.binpb`))) return { ok: true, out: "no released.binpb yet" };
  return await run("buf", [
    "breaking",
    `${dir}/descriptor.binpb`,
    "--against",
    `${dir}/released.binpb`,
    "--config",
    JSON.stringify({ version: "v2", breaking: { use: ["WIRE_JSON"] } }),
  ]);
}

if (import.meta.main) {
  const [a, b] = Deno.args;
  if (a === "breaking" && b) {
    const r = await breaking(b);
    console.log(r.out);
    Deno.exit(r.ok ? 0 : 1);
  } else if (a) {
    const { routes } = await generate(a);
    console.log(`pronto-api: wrote ${a}/api/v1 (${routes.length} routes)`);
  } else throw new Error("usage: generate.ts <app-dir> | generate.ts breaking <app-dir>");
}
