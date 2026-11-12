// pronto-api's generator (pronto-plugins docs/pronto-api.md, PRONTO-324). From an app's api_spec.cue
// and program.cue, through api_plugin.cue's `apiContract`, it writes the app's API:
//   api/v1/api_v1.sql       the schema api_v1: one security_invoker view per resource and its grants,
//                           replayed by every release (CREATE OR REPLACE VIEW refuses to drop,
//                           rename or retype a column, the first guard of v1's stability)
//   api_door.cue            the door's /api/v1 routes, each rewritten to one PostgREST call on a view
//   api/v1/openapi.json     OpenAPI 3.1 for those routes
//   api/v1/contract.json    every resource, field, type and route, sorted
// and `check` holds contract.json to the last release's (api/v1/released.json): additive only, so
// a resource, method or field removed, or a field retyped, fails. Nothing here names an app.
//   generate.ts <app-dir>         write the API
//   generate.ts check <app-dir>   the additive-only check against released.json
//   generate.ts route <app-dir>   put the door's block into the app's docker/Caddyfile (after
//                                 pronto's writer, which rewrites it)

export interface Field {
  name: string;
  column: string;
  type: string;
  writable: boolean;
}
export interface Resource {
  collection: string;
  view: string;
  table: string;
  parent?: { collection: string; column: string };
  key: { column: string; type: string };
  fields: Field[];
  methods: ("get" | "list" | "create" | "update" | "delete")[];
}
export interface Spec {
  version: string;
  schema: string;
  /** The flag (pronto-flags) the API rides: off for a caller, every view is empty to them and
   * refuses their writes. */
  flag?: string;
  resources: Resource[];
  types: Record<string, { pg: string; json: string; format?: string }>;
}
/** One door route: the Google route a client calls, and the PostgREST call it becomes. */
export interface Route {
  method: string;
  path: string;
  view: string;
  verb: string;
  query: string;
  object: boolean;
  prefer?: string;
  ifMatch?: boolean;
  pageSize?: boolean;
}
export interface Contract {
  version: string;
  resources: { collection: string; fields: { name: string; type: string; writable: boolean }[]; methods: string[] }[];
  routes: { method: string; path: string }[];
}

const tool = (name: string) => Deno.env.get(name.toUpperCase()) ?? name;
const exists = (p: string) => Deno.stat(p).then(() => true, () => false);

async function cueJson(args: string[], cwd: string) {
  const r = await new Deno.Command(tool("cue"), { args: ["export", ...args, "--out", "json"], cwd, stdout: "piped", stderr: "piped" }).output();
  const dec = new TextDecoder();
  if (!r.success) throw new Error(`api: cue export ${args.join(" ")}: ${dec.decode(r.stderr).trim()}`);
  return JSON.parse(dec.decode(r.stdout));
}

/** The app's API, as api_plugin.cue resolves it from api_spec.cue and program.cue. */
export const specOf = (app: string): Promise<Spec> => cueJson([".", "-e", "apiContract"], app);

// A path segment the door takes as an id: nothing that could end a PostgREST filter or start another.
const ID = "([A-Za-z0-9_.~-]+)";
// A plain name, quoted, so a reserved word (`user`, `order`) is a name too.
const ident = (s: string) => {
  if (!/^[a-z_][a-z0-9_]*$/.test(s)) throw new Error(`api: ${JSON.stringify(s)} is not a plain SQL name`);
  return `"${s}"`;
};

/** The resource name's template, `{collection}/{id}` under its parent: path and filter value. */
function nameOf(r: Resource, version: string) {
  const parts = r.parent ? [r.parent.collection, ID, r.collection] : [r.collection];
  const path = `/api/${version}/${parts.join("/")}`;
  const value = (n: number[]) =>
    r.parent ? `${r.parent.collection}/{re.$.${n[0]}}/${r.collection}` : r.collection;
  return { path, value };
}

/** A view column: its public name, the SQL that computes it, its type and whether it is written. */
export interface Column {
  name: string;
  sql: string;
  type: string;
  writable: boolean;
}

/** The view's columns, in the order the view keeps for ever: `released` (the last release's
 * columns of this resource) first, then the new ones. Postgres's CREATE OR REPLACE VIEW only adds
 * columns at the end, so a column released is never moved. A new view starts with name, etag and
 * parent, then the key and the public fields by name, then the stamps. */
export function columnsOf(r: Resource, released: string[] = []): Column[] {
  const key = (c: string) => `t.${ident(c)}::text`;
  const parentName = r.parent ? `'${r.parent.collection}/' || ${key(r.parent.column)}` : "";
  const base: Column[] = [
    { name: "name", sql: r.parent ? `(${parentName} || '/${r.collection}/' || ${key(r.key.column)})` : `('${r.collection}/' || ${key(r.key.column)})`, type: "string", writable: false },
    // The etag hashes what the resource shows, never a column it does not.
    { name: "etag", sql: `md5(row(${r.fields.map((f) => `t.${ident(f.column)}`).join(", ")})::text)`, type: "string", writable: false },
    ...(r.parent ? [{ name: "parent", sql: `(${parentName})`, type: "string", writable: false }] : []),
    ...r.fields.map((f) => ({ name: f.name, sql: `t.${ident(f.column)}`, type: f.type, writable: f.writable })),
  ];
  const at = (c: Column) => { const i = released.indexOf(c.name); return i < 0 ? released.length + base.indexOf(c) : i; };
  return [...base].sort((a, b) => at(a) - at(b));
}

/** The view of a resource and its grants: security_invoker, so the table's RLS judges every read
 * and write as the caller. A public field stays a plain column reference, so the view is
 * auto-updatable and Postgres maps a write back onto the table. */
export function viewSql(r: Resource, schema: string, released: string[] = [], gated = false): string {
  const cols = columnsOf(r, released);
  // Writes are granted column by column: only the public fields, never a stamp, and never the key
  // after Create; a write naming another column is refused (42501) before RLS is asked.
  const writable = cols.filter((c) => c.writable).map((c) => c.name);
  const keyName = r.fields.find((f) => f.column === r.key.column)?.name;
  const updatable = writable.filter((n) => n !== keyName);
  const list = (ns: string[]) => ns.map(ident).join(", ");
  const privileges = [
    "SELECT",
    ...(r.methods.includes("create") ? [`INSERT (${list(writable)})`] : []),
    ...(r.methods.includes("update") && updatable.length ? [`UPDATE (${list(updatable)})`] : []),
    ...(r.methods.includes("delete") ? ["DELETE"] : []),
  ];
  const v = `${ident(schema)}.${ident(r.view)}`;
  return [
    `CREATE OR REPLACE VIEW ${v} WITH (security_invoker = true${gated ? ", check_option = local" : ""}) AS`,
    `  SELECT ${cols.map((c) => `${c.sql} AS ${ident(c.name)}`).join(",\n         ")}`,
    `  FROM public.${ident(r.table)} t${gated ? `\n  WHERE ${GATE}(public.auth_uid())` : ""};`,
    `REVOKE ALL ON ${v} FROM PUBLIC, anon;`,
    `GRANT ${privileges.join(", ")} ON ${v} TO app_user;`,
    // A stamp is the server's: a Create sets it to now() (the table may have no default of its own,
    // and the caller may not name it).
    ...(r.methods.includes("create") ? cols.filter((c) => c.name === "create_time" || c.name === "update_time").map((c) => `ALTER VIEW ${v} ALTER COLUMN ${ident(c.name)} SET DEFAULT now();`) : []),
  ].join("\n");
}

/** The flag's gate: whether the API is on for an account, as pronto-flags says (its
 * pronto_flags.flag_on). The views ask it for the caller; the auth service asks it, as the app's
 * capabilities.auth.apiKeysGate, before it makes, lists or exchanges a key. In api_private, which
 * PostgREST does not serve. */
const GATE = "api_private.api_on";
function gateSql(flag: string): string {
  if (!/^[a-z][a-z0-9_-]{0,63}$/.test(flag)) throw new Error(`api: ${JSON.stringify(flag)} is not a flag's name`);
  return [
    `CREATE SCHEMA IF NOT EXISTS api_private;`,
    `REVOKE ALL ON SCHEMA api_private FROM PUBLIC;`,
    `GRANT USAGE ON SCHEMA api_private TO app_user;`,
    `CREATE OR REPLACE FUNCTION ${GATE}(owner uuid) RETURNS boolean`,
    `LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog AS $f$`,
    `  SELECT pronto_flags.flag_on('${flag}', owner)`,
    `$f$;`,
    `REVOKE EXECUTE ON FUNCTION ${GATE}(uuid) FROM PUBLIC;`,
    `GRANT EXECUTE ON FUNCTION ${GATE}(uuid) TO app_user;`,
  ].join("\n");
}

/** The whole api_v1.sql: the schema, the flag's gate, each view and its grants, and PostgREST told
 * to reload. */
export function sqlOf(spec: Spec, released?: Contract): string {
  const s = ident(spec.schema);
  return [
    `-- pronto-api: the app's ${spec.schema} (api/${spec.version}/${spec.schema}.sql). Generated, do not edit.`,
    // A replayed migration waits on a lock for so long, and runs for so long, and no longer.
    `SET lock_timeout = '30s';\nSET statement_timeout = '60s';`,
    `CREATE SCHEMA IF NOT EXISTS ${s};`,
    `REVOKE ALL ON SCHEMA ${s} FROM PUBLIC;`,
    `GRANT USAGE ON SCHEMA ${s} TO app_user;`,
    ...(spec.flag ? [gateSql(spec.flag)] : []),
    ...spec.resources.map((r) => viewSql(r, spec.schema, releasedColumns(released, r), !!spec.flag)),
    `NOTIFY pgrst, 'reload schema';`,
    "",
  ].join("\n\n");
}

/** The door's routes: each standard method a resource exports, as one PostgREST call on its view. */
export function routesOf(spec: Spec): Route[] {
  const out: Route[] = [];
  for (const r of spec.resources) {
    const n = nameOf(r, spec.version);
    const k = r.parent ? 2 : 1; // the id's capture group
    const one = `name=eq.${n.value([1])}/{re.$.${k}}`;
    const item = `${n.path}/${ID}`;
    if (r.methods.includes("get")) out.push({ method: "GET", path: item, view: r.view, verb: "GET", query: one, object: true });
    if (r.methods.includes("list")) {
      const within = r.parent ? `&parent=eq.${r.parent.collection}/{re.$.1}` : "";
      out.push({ method: "GET", path: n.path, view: r.view, verb: "GET", query: `order=name.asc&name=gt.{query.after}${within}`, object: false, pageSize: true });
    }
    if (r.methods.includes("create")) out.push({ method: "POST", path: n.path, view: r.view, verb: "POST", query: "", object: true, prefer: "return=representation" });
    if (r.methods.includes("update")) out.push({ method: "PATCH", path: item, view: r.view, verb: "PATCH", query: one, object: true, prefer: "return=representation", ifMatch: true });
    if (r.methods.includes("delete")) out.push({ method: "DELETE", path: item, view: r.view, verb: "DELETE", query: one, object: false, prefer: "return=minimal" });
  }
  return out;
}

/** The routes as a Caddyfile block: a route the spec does not generate is 404, the client's query,
 * Prefer and Accept-Profile never reach PostgREST, and the profile is the API's schema. */
export function caddyOf(spec: Spec, routes: Route[]): string {
  // No request picks PostgREST's schema itself: /crud stays on public, and the API's handles name
  // theirs below (request_header runs before any handle).
  const strip = [`request_header -Accept-Profile`, `request_header -Content-Profile`];
  // A handle, so it sits beside the door's /crud handle; inside, a route keeps the written order.
  const lines = [`handle /api/${spec.version}/* {`, `  route {`];
  const upstream = [
    `    reverse_proxy {$PRONTO_UPSTREAM_CRUD:crud:3000} {`,
    `      header_up dapr-app-id crud`,
    `      import bounded-crud`,
    `    }`,
  ];
  routes.forEach((r, i) => {
    const id = `api_${i}`;
    const regexp = `^${r.path}$`;
    const handle = (suffix: string, extra: string[], query: string) => {
      const m = `${id}${suffix}`;
      const q = query.replaceAll("{re.$.", `{re.${id}.`);
      lines.push(`  @${m} {`, `    method ${r.method}`, `    path_regexp ${id} ${regexp}`, ...extra.map((e) => `    ${e}`), `  }`);
      lines.push(`  handle @${m} {`);
      // Always a `?`: a rewrite without one keeps the client's query.
      lines.push(`    rewrite * /${r.view}?${q}`);
      lines.push(`    request_header -Prefer`, `    request_header -Accept-Profile`, `    request_header -Content-Profile`, `    request_header -Range`, `    request_header -Range-Unit`);
      // JSON only: PostgREST would take CSV or a form as a bulk write.
      if (r.verb === "POST" || r.verb === "PATCH") lines.push(`    request_header Content-Type application/json`);
      lines.push(r.verb === "GET" ? `    request_header Accept-Profile ${spec.schema}` : `    request_header Content-Profile ${spec.schema}`);
      if (r.verb !== "GET") lines.push(`    request_header Accept-Profile ${spec.schema}`);
      lines.push(`    request_header Accept ${r.object ? "application/vnd.pgrst.object+json" : "application/json"}`);
      if (r.prefer) lines.push(`    request_header Prefer ${r.prefer}`);
      lines.push(...upstream, `  }`);
    };
    if (r.pageSize) {
      // A cursor is a resource name: anything else (an `&` that would start a filter) is 404.
      // One expression a matcher: caddy keeps only the last of two.
      const after = `{query.after}.matches('^[A-Za-z0-9_.~/-]*$')`;
      handle("_sized", [`expression ${after} && {query.page_size}.matches('^([1-9]|[1-9][0-9]|1[0-9][0-9]|200)$')`], `${r.query}&limit={query.page_size}`);
      handle("", [`expression ${after}`], `${r.query}&limit=50`);
    } else if (r.ifMatch) {
      handle("_if", [`header_regexp ${id}_etag If-Match ^"?([0-9a-f]{32})"?$`], `${r.query}&etag=eq.{re.${id}_etag.1}`);
      handle("", [`not header If-Match *`], r.query);
    } else handle("", [], r.query);
  });
  lines.push(`  handle {`, `    respond 404`, `  }`);
  return [...strip, lines[0], lines[1], ...lines.slice(2).map((l) => `  ${l}`), `  }`, `}`].join("\n") + "\n";
}

/** api_door.cue: the routes as data and as the Caddyfile block the door carries (route() puts it
 * in docker/Caddyfile; the spec's flag is the views' gate, per request, as a flag must be), and the
 * headers the block strips from every request so /crud never reaches the API's schema. */
export function doorOf(spec: Spec, routes: Route[]): string {
  const caddy = caddyOf(spec, routes).replace(/\n$/, "").split("\n").map((l) => `\t${l}`).join("\n");
  return [
    "// generated by pronto-api's generate — do not edit",
    "package __PACKAGE__",
    "",
    `apiDoor: routes: ${JSON.stringify(routes.map((r) => ({ method: r.method, path: r.path, view: r.view })), null, "\t").replaceAll("\n", "\n")}`,
    `apiDoor: crudStrips: ["Accept-Profile", "Content-Profile"]`,
    `apiDoor: caddy: """\n${caddy}\n\t"""`,
    "",
  ].join("\n");
}

/** The Google route a client sees for each door route, `{collection}/{id}` named as AIP-122 does. */
function googlePath(r: Route, spec: Spec): string {
  const res = spec.resources.find((x) => x.view === r.view)!;
  let i = 0;
  const names = res.parent ? [res.parent.collection.replace(/s$/, ""), res.view] : [res.view];
  return r.path.replaceAll(ID, () => `{${names[i++] ?? "id"}}`);
}

/** The contract: every resource's public fields and their types, its methods, and every route. */
const releasedColumns = (released: Contract | undefined, r: Resource) =>
  released?.resources.find((x) => x.collection === r.collection)?.fields.map((f) => f.name) ?? [];

/** The contract: every resource's columns in the view's order with their types and whether they
 * are written, its methods, and every route. */
export function contractOf(spec: Spec, routes: Route[], released?: Contract): Contract {
  return {
    version: spec.version,
    resources: spec.resources.map((r) => ({
      collection: r.collection,
      fields: columnsOf(r, releasedColumns(released, r)).map((c) => ({ name: c.name, type: c.type, writable: c.writable })),
      methods: [...r.methods].sort(),
    })).sort((a, b) => a.collection.localeCompare(b.collection)),
    routes: routes.map((r) => ({ method: r.method, path: googlePath(r, spec) })).sort((a, b) => `${a.path} ${a.method}`.localeCompare(`${b.path} ${b.method}`)),
  };
}

/** OpenAPI 3.1 for the routes, each resource a schema, PostgREST's error body for every error. */
export function openapiOf(spec: Spec, routes: Route[]): Record<string, unknown> {
  const schemas: Record<string, unknown> = {
    Error: { type: "object", properties: { code: { type: "string" }, message: { type: "string" }, details: { type: ["string", "null"] }, hint: { type: ["string", "null"] } } },
  };
  for (const r of spec.resources) {
    const props: Record<string, unknown> = { name: { type: "string", readOnly: true }, etag: { type: "string", readOnly: true }, ...(r.parent ? { parent: { type: "string", readOnly: true } } : {}) };
    for (const f of r.fields) {
      const t = spec.types[f.type];
      props[f.name] = { type: t.json, ...(t.format ? { format: t.format } : {}), ...(f.writable ? {} : { readOnly: true }) };
    }
    schemas[r.view] = { type: "object", properties: props };
  }
  const paths: Record<string, Record<string, unknown>> = {};
  const errors = { default: { description: "PostgREST's error", content: { "application/json": { schema: { $ref: "#/components/schemas/Error" } } } } };
  for (const r of routes) {
    const p = googlePath(r, spec);
    const ref = { $ref: `#/components/schemas/${r.view}` };
    const params = [...p.matchAll(/\{([a-z_]+)\}/g)].map((m) => ({ name: m[1], in: "path", required: true, schema: { type: "string" } }));
    if (r.pageSize) params.push({ name: "page_size", in: "query", required: false, schema: { type: "integer", minimum: 1, maximum: 200, default: 50 } as never }, { name: "after", in: "query", required: false, schema: { type: "string" } });
    if (r.ifMatch) params.push({ name: "If-Match", in: "header", required: false, schema: { type: "string" } });
    const ok = r.method === "DELETE"
      ? { 204: { description: "deleted" } }
      : { [r.method === "POST" ? 201 : 200]: { description: "ok", content: { "application/json": { schema: r.pageSize ? { type: "array", items: ref } : ref } } } };
    (paths[p] ??= {})[r.method.toLowerCase()] = {
      operationId: `${r.method.toLowerCase()}_${r.view}${r.pageSize ? "_list" : ""}`,
      parameters: params,
      ...(r.method === "POST" || r.method === "PATCH" ? { requestBody: { required: true, content: { "application/json": { schema: ref } } } } : {}),
      responses: { ...ok, ...errors },
    };
  }
  return { openapi: "3.1.0", info: { title: "API", version: spec.version }, paths, components: { schemas } };
}

/** What the current contract breaks of the released one: a resource, method, route or field gone,
 * or a field retyped. Additions break nothing. */
export function breaks(released: Contract, now: Contract): string[] {
  const out: string[] = [];
  for (const r of released.resources) {
    const n = now.resources.find((x) => x.collection === r.collection);
    if (!n) { out.push(`resource ${r.collection} removed`); continue; }
    for (const m of r.methods) if (!n.methods.includes(m)) out.push(`${r.collection}: method ${m} removed`);
    for (const f of r.fields) {
      const g = n.fields.find((x) => x.name === f.name);
      if (!g) out.push(`${r.collection}.${f.name} removed`);
      else if (g.type !== f.type) out.push(`${r.collection}.${f.name} retyped: released as ${f.type}, now ${g.type}`);
      else if (f.writable && !g.writable) out.push(`${r.collection}.${f.name} no longer written`);
    }
  }
  for (const r of released.routes) if (!now.routes.some((x) => x.method === r.method && x.path === r.path)) out.push(`route ${r.method} ${r.path} removed`);
  return out;
}

const pkg = async (app: string) => {
  for await (const e of Deno.readDir(app)) {
    if (!e.isFile || !e.name.endsWith(".cue")) continue;
    const m = /^package\s+([A-Za-z_][A-Za-z0-9_]*)/m.exec(await Deno.readTextFile(`${app}/${e.name}`));
    if (m) return m[1];
  }
  throw new Error(`api: no CUE package in ${app}`);
};

/** A file written only when its text changes, so a generate that changes nothing leaves every
 * watch and build cache where it was; replaced in one rename. */
async function save(path: string, text: string) {
  if ((await Deno.readTextFile(path).catch(() => null)) === text) return;
  const tmp = `${path}.${Deno.pid}.tmp`;
  await Deno.writeTextFile(tmp, text);
  await Deno.rename(tmp, path);
}

const BEGIN = "  # pronto-api:begin — the app's API (api_spec.cue), each route one PostgREST call on a view";
const END = "  # pronto-api:end";

/** The door's Caddyfile with the API's block, an earlier one taken out first: in the (app) snippet
 * every listener imports, before the first `handle /auth/*` and the comments it carries, as every
 * plugin's route step places its block (pronto's caddy-blocks.ts keeps it there across a rewrite). */
export function routed(caddyfile: string, block: string): string {
  let lines = caddyfile.split("\n");
  const from = lines.indexOf(BEGIN), to = lines.indexOf(END);
  if (from >= 0 && to > from) lines = [...lines.slice(0, from), ...lines.slice(to + 1)];
  const at = lines.findIndex((l) => l.startsWith("  handle /auth/*"));
  if (at < 0) throw new Error("api: docker/Caddyfile has no `handle /auth/*` to place the API's routes before");
  let start = at;
  while (start > 0 && lines[start - 1].startsWith("  #") && !lines[start - 1].endsWith(":end")) start--;
  const own = block.replace(/\n$/, "").split("\n").map((l) => (l ? `  ${l}` : l));
  return [...lines.slice(0, start), BEGIN, ...own, END, ...lines.slice(start)].join("\n");
}

/** Puts the API's block into the app's docker/Caddyfile. */
export async function route(app: string) {
  const spec = await specOf(app);
  const path = `${app}/docker/Caddyfile`;
  await save(path, routed(await Deno.readTextFile(path), caddyOf(spec, routesOf(spec))));
}

/** Writes the app's API and answers what it wrote. */
export async function generate(app: string) {
  const spec = await specOf(app);
  const routes = routesOf(spec);
  const dir = `${app}/api/${spec.version}`;
  await Deno.mkdir(dir, { recursive: true });
  const released = await releasedOf(dir);
  const sql = sqlOf(spec, released);
  const contract = contractOf(spec, routes, released);
  const door = doorOf(spec, routes).replace("__PACKAGE__", await pkg(app));
  await save(`${dir}/${spec.schema}.sql`, sql);
  await save(`${app}/api_door.cue`, door);
  await save(`${dir}/openapi.json`, JSON.stringify(openapiOf(spec, routes), null, 2) + "\n");
  await save(`${dir}/contract.json`, JSON.stringify(contract, null, 2) + "\n");
  return { sql, routes, contract, door };
}

/** The additive-only check: what contract.json breaks of released.json (none when nothing is
 * released yet). */
export async function check(app: string): Promise<string[]> {
  const spec = await specOf(app);
  const released = await releasedOf(`${app}/api/${spec.version}`);
  if (!released) return [];
  // The contract as the spec gives it now, not the file, which may be stale.
  return breaks(released, contractOf(spec, routesOf(spec), released));
}

/** The last release's contract, none before the first release. */
async function releasedOf(dir: string): Promise<Contract | undefined> {
  return (await exists(`${dir}/released.json`)) ? JSON.parse(await Deno.readTextFile(`${dir}/released.json`)) : undefined;
}

if (import.meta.main) {
  const [a, b] = Deno.args;
  if (a === "check") {
    const found = await check(b);
    if (found.length) {
      console.error(`api: the contract breaks the released one:\n  ${found.join("\n  ")}`);
      Deno.exit(1);
    }
  } else if (a === "route") await route(b);
  else await generate(a);
}
