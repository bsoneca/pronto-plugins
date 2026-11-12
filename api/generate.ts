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
  /** The exported machines (PRONTO-314): each a collection of rooms. */
  machines?: Machine[];
  types: Record<string, { pg: string; json: string; format?: string }>;
}
/** An exported machine: its reducer's surface tables, protocol version, the events a client may
 * send (tier omnishell) and the open kinds it may ask for, and its public table's fields. */
export interface Machine {
  collection: string;
  view: string;
  machine: string;
  version: number;
  tables: { seat: string; command: string; open?: string; public?: string };
  events: string[];
  opens: ("create" | "join")[];
  public?: { name: string; column: string; type: string }[];
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
  /** A machine's route: the room's name and the event (or open kind) the door hands its trigger in
   * X-Api-Name and X-Api-Event, and the path a client sees. */
  apiName?: string;
  apiEvent?: string;
  google?: string;
  /** A Create's room id, from the query (`?{view}_id=`). */
  createId?: string;
}
export interface Contract {
  version: string;
  resources: { collection: string; fields: { name: string; type: string; writable: boolean }[]; methods: string[] }[];
  machines?: { collection: string; fields: { name: string; type: string }[]; events: string[]; opens: string[] }[];
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
 * pronto_flags.flag_on_strict: a targeting rule that fails raises, so the gate fails closed). The views ask it for the caller; the auth service asks it, as the app's
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
    `  SELECT pronto_flags.flag_on_strict('${flag}', owner)`,
    `$f$;`,
    `REVOKE EXECUTE ON FUNCTION ${GATE}(uuid) FROM PUBLIC;`,
    `GRANT EXECUTE ON FUNCTION ${GATE}(uuid) TO app_user;`,
  ].join("\n");
}

// A room's id: a uuid, the machine's instance_id.
const UUID = "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}";
// A client's request_id: what a command id can carry as its last part.
const REQUEST_ID = "^[A-Za-z0-9_-]{1,36}$";
/** An event's custom method, lowerCamelCase (`make_move` is `:makeMove`). */
export const camel = (e: string) => e.replace(/_([a-z0-9])/g, (_, c: string) => c.toUpperCase());
const lit = (s: string) => `'${s.replaceAll("'", "''")}'`;

/** A machine's views and their triggers (PRONTO-314, v1): the machine runs as it does for the
 * browser, so nothing here changes how a room advances.
 *   <view>          the caller's seat in a room (Get): seat, phase, view, etag (the seat's revision)
 *   <view>_public   the public table (List), when the spec exports one
 *   <view>_command  an event (`POST {room}:{event}`): an INSTEAD OF INSERT trigger builds the
 *                   machine's command row from the door's headers and the body (payload, etag,
 *                   request_id), lets the machine's own AFTER trigger judge it, and answers its
 *                   outcome; a rejection raises, so nothing is stored
 *   <view>_open     Create and join, the same way over the open table
 * Idempotency is the machine's: the command id carries request_id, so a retry is the stored row. */
export function machineSql(m: Machine, schema: string, gated: boolean): string {
  const v = (n: string) => `${ident(schema)}.${ident(n)}`;
  const t = (n: string) => `public.${ident(n)}`;
  const where = gated ? `\n  WHERE ${GATE}(public.auth_uid())` : "";
  const opts = `WITH (security_invoker = true)`;
  const room = `(${lit(m.collection + "/")} || t."instance_id"::text)`;
  const out: string[] = [];
  const grant = (n: string, extra = "") => out.push(`REVOKE ALL ON ${v(n)} FROM PUBLIC, anon;`, `GRANT SELECT${extra} ON ${v(n)} TO app_user;`);
  // Get: the caller's seat (the table's RLS shows a player only their own).
  out.push(
    `CREATE OR REPLACE VIEW ${v(m.view)} ${opts} AS`,
    `  SELECT ${room} AS "name",\n         t."revision"::text AS "etag",\n         t."seat" AS "seat",\n         t."phase" AS "phase",\n         t."view" AS "view"`,
    `  FROM ${t(m.tables.seat)} t${where};`,
  );
  grant(m.view);
  if (m.tables.public && m.public) {
    const cols = m.public.map((f) => `t.${ident(f.column)} AS ${ident(f.name)}`);
    out.push(
      `CREATE OR REPLACE VIEW ${v(m.view + "_public")} ${opts} AS`,
      `  SELECT (${lit(m.collection + "/")} || t."id"::text) AS "name",\n         md5(row(${m.public.map((f) => `t.${ident(f.column)}`).join(", ")})::text) AS "etag",\n         ${cols.join(",\n         ")}`,
      `  FROM ${t(m.tables.public)} t${where};`,
    );
    grant(m.view + "_public");
  }
  // The door's headers: the room's name and the event, never the client's (the block strips both).
  const header = (h: string) => `nullif(current_setting('request.headers', true), '')::json->>${lit(h)}`;
  const raise = (code: string, message: string, detail?: string) =>
    `RAISE SQLSTATE ${lit(code)} USING MESSAGE = ${lit(message)}${detail ? `, DETAIL = ${detail}` : ""};`;
  const prologue = (kinds: string[]) => [
    `DECLARE`,
    `  room_name text := ${header("x-api-name")};`,
    `  kind text := ${header("x-api-event")};`,
    `  room uuid;`,
    `  got record;`,
    `BEGIN`,
    ...(gated ? [`  IF NOT ${GATE}(public.auth_uid()) THEN ${raise("PT403", "api_off")} END IF;`] : []),
    `  IF room_name IS NULL OR room_name !~ ${lit(`^${m.collection}/${UUID}$`)} OR kind IS NULL OR NOT (kind = ANY (ARRAY[${kinds.map(lit).join(", ")}]::text[])) THEN`,
    `    ${raise("PT404", "not_found")}`,
    `  END IF;`,
    `  room := substr(room_name, ${m.collection.length + 2})::uuid;`,
    `  IF NEW."request_id" IS NULL OR NEW."request_id" !~ ${lit(REQUEST_ID)} THEN ${raise("PT400", "invalid_argument", lit("request_id"))} END IF;`,
  ];
  // The machine's answer: a rejection raises (the call rolls back, so nothing is stored and a retry
  // is judged again), stale_revision as 409.
  const judged = [
    `  IF got."outcome" = 'rejected' THEN`,
    `    IF got."reason" = 'stale_revision' THEN ${raise("PT409", "stale_revision", "got.\"reason\"")} END IF;`,
    `    ${raise("P0001", "rejected", "got.\"reason\"")}`,
    `  END IF;`,
  ];
  const fn = (name: string, body: string[]) => [
    `CREATE OR REPLACE FUNCTION api_private.${ident(name)}() RETURNS trigger`,
    `LANGUAGE plpgsql SET search_path = pg_catalog AS $f$`,
    ...body,
    `END`,
    `$f$;`,
    `REVOKE EXECUTE ON FUNCTION api_private.${ident(name)}() FROM PUBLIC;`,
  ];
  const trigger = (view: string, name: string) => [
    `CREATE OR REPLACE TRIGGER "write" INSTEAD OF INSERT ON ${v(view)} FOR EACH ROW EXECUTE FUNCTION api_private.${ident(name)}();`,
  ];
  // An event: the command view.
  {
    const view = m.view + "_command";
    const name = `${m.view}_command`;
    out.push(
      `CREATE OR REPLACE VIEW ${v(view)} ${opts} AS`,
      `  SELECT ${room} AS "name",\n         split_part(t."id", '/', 5) AS "request_id",\n         t."request"->'event'->>'kind' AS "event",\n         t."request"->'event'->'payload' AS "payload",\n         t."revision"::text AS "etag",\n         t."outcome" AS "outcome",\n         t."reason" AS "reason"`,
      `  FROM ${t(m.tables.command)} t${where};`,
      ...fn(name, [
        ...prologue(m.events),
        `  IF NEW."etag" IS NULL OR NEW."etag" !~ '^[0-9]{1,20}$' THEN ${raise("PT400", "invalid_argument", lit("etag"))} END IF;`,
        `  DECLARE`,
        `    s record;`,
        `    req json;`,
        `    cid text;`,
        `  BEGIN`,
        `    SELECT x."seat" INTO s FROM ${t(m.tables.seat)} x WHERE x."instance_id" = room AND x."actor" = public.auth_uid();`,
        `    IF NOT FOUND THEN ${raise("PT404", "not_found")} END IF;`,
        `    req := json_build_object('event', json_build_object('kind', kind, 'payload', coalesce(NEW."payload", '{}'::json)), 'expected_revision', NEW."etag", 'version', ${m.version});`,
        `    cid := room::text || '/' || NEW."etag" || '/' || s."seat" || '/' || kind || '/' || NEW."request_id";`,
        // The machine's receipt: an earlier call with this request_id is answered from its row, and
        // the same request_id with another body is a conflict.
        `    SELECT c."id", c."request", c."revision", c."outcome", c."reason" INTO got FROM ${t(m.tables.command)} c`,
        `      WHERE c."instance_id" = room AND c."actor" = public.auth_uid() AND split_part(c."id", '/', 5) = NEW."request_id";`,
        `    IF FOUND AND (got."id" <> cid OR got."request"::jsonb <> req::jsonb) THEN ${raise("PT409", "idempotency_conflict", lit("request_id"))} END IF;`,
        `    IF NOT FOUND THEN`,
        `      INSERT INTO ${t(m.tables.command)} ("id", "instance_id", "request") VALUES (cid, room, req) ON CONFLICT ("id") DO NOTHING;`,
        `      SELECT c."id", c."request", c."revision", c."outcome", c."reason" INTO got FROM ${t(m.tables.command)} c WHERE c."id" = cid;`,
        `      IF NOT FOUND THEN ${raise("PT409", "idempotency_conflict", lit("request_id"))} END IF;`,
        `    END IF;`,
        `  END;`,
        ...judged,
        `  NEW."name" := room_name;`,
        `  NEW."event" := kind;`,
        `  NEW."payload" := got."request"->'event'->'payload';`,
        `  NEW."etag" := got."revision"::text;`,
        `  NEW."outcome" := got."outcome";`,
        `  NEW."reason" := got."reason";`,
        `  RETURN NEW;`,
      ]),
      ...trigger(view, name),
    );
    grant(view, `, INSERT ("payload", "etag", "request_id")`);
  }
  // Create and join: the open view.
  if (m.opens.length && m.tables.open) {
    const view = m.view + "_open";
    const name = `${m.view}_open`;
    out.push(
      `CREATE OR REPLACE VIEW ${v(view)} ${opts} AS`,
      `  SELECT ${room} AS "name",\n         split_part(t."id", '/', 3) AS "request_id",\n         t."kind" AS "kind",\n         t."input" AS "input",\n         t."outcome" AS "outcome",\n         t."reason" AS "reason"`,
      `  FROM ${t(m.tables.open)} t${where};`,
      ...fn(name, [
        ...prologue(m.opens),
        `  DECLARE`,
        `    open_id text := room::text || '/' || kind || '/' || NEW."request_id";`,
        `    input json := coalesce(NEW."input", '{}'::json);`,
        `  BEGIN`,
        `    SELECT o."id", o."input", o."outcome", o."reason" INTO got FROM ${t(m.tables.open)} o WHERE o."id" = open_id;`,
        `    IF FOUND AND got."input"::jsonb <> input::jsonb THEN ${raise("PT409", "idempotency_conflict", lit("request_id"))} END IF;`,
        `    IF NOT FOUND THEN`,
        `      INSERT INTO ${t(m.tables.open)} ("id", "instance_id", "kind", "input") VALUES (open_id, room, kind, input) ON CONFLICT ("id") DO NOTHING;`,
        `      SELECT o."id", o."input", o."outcome", o."reason" INTO got FROM ${t(m.tables.open)} o WHERE o."id" = open_id;`,
        `      IF NOT FOUND THEN ${raise("PT409", "idempotency_conflict", lit("request_id"))} END IF;`,
        `    END IF;`,
        `  END;`,
        ...judged,
        `  NEW."name" := room_name;`,
        `  NEW."kind" := kind;`,
        `  NEW."input" := got."input";`,
        `  NEW."outcome" := got."outcome";`,
        `  NEW."reason" := got."reason";`,
        `  RETURN NEW;`,
      ]),
      ...trigger(view, name),
    );
    grant(view, `, INSERT ("input", "request_id")`);
  }
  return out.join("\n");
}

/** The whole api_v1.sql: the schema, the flag's gate, each view and its grants, and PostgREST told
 * to reload. */
export function sqlOf(spec: Spec, released?: Contract): string {
  const s = ident(spec.schema);
  return [
    `-- pronto-api: the app's ${spec.schema} (api/${spec.version}/${spec.schema}.sql). Generated, do not edit.`,
    `CREATE SCHEMA IF NOT EXISTS ${s};`,
    `REVOKE ALL ON SCHEMA ${s} FROM PUBLIC;`,
    `GRANT USAGE ON SCHEMA ${s} TO app_user;`,
    ...(spec.flag ? [gateSql(spec.flag)] : []),
    ...spec.resources.map((r) => viewSql(r, spec.schema, releasedColumns(released, r), !!spec.flag)),
    ...(spec.machines?.length ? [`CREATE SCHEMA IF NOT EXISTS api_private;\nREVOKE ALL ON SCHEMA api_private FROM PUBLIC;\nGRANT USAGE ON SCHEMA api_private TO app_user;`] : []),
    ...(spec.machines ?? []).map((m) => machineSql(m, spec.schema, !!spec.flag)),
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
  for (const m of spec.machines ?? []) {
    const base = `/api/${spec.version}/${m.collection}`;
    const room = `{${m.view}}`;
    const named = `${m.collection}/{re.$.1}`;
    const write = { verb: "POST", query: "", object: true, prefer: "return=representation" };
    out.push({ method: "GET", path: `${base}/${ID}`, view: m.view, verb: "GET", query: `name=eq.${named}`, object: true, google: `${base}/${room}` });
    if (m.public) out.push({ method: "GET", path: base, view: `${m.view}_public`, verb: "GET", query: "order=name.asc&name=gt.{query.after}", object: false, pageSize: true, google: base });
    if (m.opens.includes("create")) out.push({ method: "POST", path: base, view: `${m.view}_open`, ...write, apiName: `${m.collection}/{vars.api_room}`, apiEvent: "create", createId: `${m.view}_id`, google: base });
    if (m.opens.includes("join")) out.push({ method: "POST", path: `${base}/${ID}:join`, view: `${m.view}_open`, ...write, apiName: named, apiEvent: "join", google: `${base}/${room}:join` });
    for (const e of m.events) out.push({ method: "POST", path: `${base}/${ID}:${camel(e)}`, view: `${m.view}_command`, ...write, apiName: named, apiEvent: e, google: `${base}/${room}:${camel(e)}` });
  }
  return out;
}

/** The routes as a Caddyfile block: a route the spec does not generate is 404, the client's query,
 * Prefer and Accept-Profile never reach PostgREST, and the profile is the API's schema. */
export function caddyOf(spec: Spec, routes: Route[]): string {
  // No request picks PostgREST's schema itself: /crud stays on public, and the API's handles name
  // theirs below (request_header runs before any handle).
  const strip = [`request_header -Accept-Profile`, `request_header -Content-Profile`, ...(spec.machines?.length ? [`request_header -X-Api-Name`, `request_header -X-Api-Event`] : [])];
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
      // The room a Create names, kept before the rewrite drops the query.
      if (r.createId) lines.push(`    vars api_room {query.${r.createId}}`);
      // Always a `?`: a rewrite without one keeps the client's query.
      lines.push(`    rewrite * /${r.view}?${q}`);
      lines.push(`    request_header -Prefer`, `    request_header -Accept-Profile`, `    request_header -Content-Profile`, `    request_header -Range`, `    request_header -Range-Unit`);
      // JSON only: PostgREST would take CSV or a form as a bulk write.
      if (r.verb === "POST" || r.verb === "PATCH") lines.push(`    request_header Content-Type application/json`);
      lines.push(r.verb === "GET" ? `    request_header Accept-Profile ${spec.schema}` : `    request_header Content-Profile ${spec.schema}`);
      if (r.verb !== "GET") lines.push(`    request_header Accept-Profile ${spec.schema}`);
      lines.push(`    request_header Accept ${r.object ? "application/vnd.pgrst.object+json" : "application/json"}`);
      if (r.prefer) lines.push(`    request_header Prefer ${r.prefer}`);
      // A machine's room and event, for its trigger: the door's, never the client's.
      if (r.apiName) lines.push(`    request_header X-Api-Name ${r.apiName.replaceAll("{re.$.", `{re.${id}.`)}`, `    request_header X-Api-Event ${r.apiEvent}`);
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
    } else if (r.createId) {
      // A Create names its room: a uuid, else no route.
      handle("", [`expression {query.${r.createId}}.matches('^${UUID}$')`], r.query);
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
  if (r.google) return r.google;
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
    ...(spec.machines?.length ? { machines: spec.machines.map((m) => ({ collection: m.collection, fields: machineFields(m), events: [...m.events].sort(), opens: [...m.opens].sort() })) } : {}),
    routes: routes.map((r) => ({ method: r.method, path: googlePath(r, spec) })).sort((a, b) => `${a.path} ${a.method}`.localeCompare(`${b.path} ${b.method}`)),
  };
}

/** A machine's seat (Get) fields, then its public (List) fields. */
function machineFields(m: Machine) {
  return [
    ...[["name", "string"], ["etag", "string"], ["seat", "string"], ["phase", "string"], ["view", "json"]].map(([name, type]) => ({ name, type })),
    ...(m.public ?? []).map((f) => ({ name: `public.${f.name}`, type: f.type })),
  ];
}

/** OpenAPI schemas of a machine: its seat, its public row, an event and an open. */
function machineSchemas(m: Machine, spec: Spec): Record<string, unknown> {
  const ro = (type: string | string[]) => ({ type, readOnly: true });
  const answer = { outcome: ro("string"), reason: ro(["string", "null"]), name: ro("string") };
  const out: Record<string, unknown> = {
    [m.view]: { type: "object", properties: { name: ro("string"), etag: ro("string"), seat: ro("string"), phase: ro("string"), view: ro("object") } },
    [`${m.view}_command`]: { type: "object", required: ["etag", "request_id"], properties: { payload: { type: "object" }, etag: { type: "string", description: "the room's etag the event was decided on; the answer's is the room's next" }, request_id: { type: "string", pattern: REQUEST_ID }, event: ro("string"), ...answer } },
  };
  if (m.opens.length) out[`${m.view}_open`] = { type: "object", required: ["request_id"], properties: { input: { type: "object" }, request_id: { type: "string", pattern: REQUEST_ID }, kind: ro("string"), ...answer } };
  if (m.public) {
    const props: Record<string, unknown> = { name: ro("string"), etag: ro("string") };
    for (const f of m.public) { const t = spec.types[f.type]; props[f.name] = { type: t.json, ...(t.format ? { format: t.format } : {}), readOnly: true }; }
    out[`${m.view}_public`] = { type: "object", properties: props };
  }
  return out;
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
  for (const m of spec.machines ?? []) Object.assign(schemas, machineSchemas(m, spec));
  const paths: Record<string, Record<string, unknown>> = {};
  const errors = { default: { description: "PostgREST's error", content: { "application/json": { schema: { $ref: "#/components/schemas/Error" } } } } };
  for (const r of routes) {
    const p = googlePath(r, spec);
    const ref = { $ref: `#/components/schemas/${r.view}` };
    const params = [...p.matchAll(/\{([a-z_]+)\}/g)].map((m) => ({ name: m[1], in: "path", required: true, schema: { type: "string" } }));
    if (r.pageSize) params.push({ name: "page_size", in: "query", required: false, schema: { type: "integer", minimum: 1, maximum: 200, default: 50 } as never }, { name: "after", in: "query", required: false, schema: { type: "string" } });
    if (r.ifMatch) params.push({ name: "If-Match", in: "header", required: false, schema: { type: "string" } });
    if (r.createId) params.push({ name: r.createId, in: "query", required: true, schema: { type: "string", format: "uuid" } as never });
    const ok = r.method === "DELETE"
      ? { 204: { description: "deleted" } }
      : { [r.method === "POST" ? 201 : 200]: { description: "ok", content: { "application/json": { schema: r.pageSize ? { type: "array", items: ref } : ref } } } };
    (paths[p] ??= {})[r.method.toLowerCase()] = {
      operationId: `${r.method.toLowerCase()}_${r.view}${r.pageSize ? "_list" : ""}${r.apiEvent ? `_${r.apiEvent}` : ""}`,
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
  for (const m of released.machines ?? []) {
    const n = now.machines?.find((x) => x.collection === m.collection);
    if (!n) { out.push(`machine ${m.collection} removed`); continue; }
    for (const e of m.events) if (!n.events.includes(e)) out.push(`${m.collection}: event ${e} removed`);
    for (const o of m.opens) if (!n.opens.includes(o)) out.push(`${m.collection}: open ${o} removed`);
    for (const f of m.fields) {
      const g = n.fields.find((x) => x.name === f.name);
      if (!g) out.push(`${m.collection}.${f.name} removed`);
      else if (g.type !== f.type) out.push(`${m.collection}.${f.name} retyped: released as ${f.type}, now ${g.type}`);
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
