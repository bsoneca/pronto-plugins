// pronto-migrations' driver (migrations/README.md in pronto-plugins): run from the app's folder.
//
//   deno run --no-config -A migrations/migrate.ts <command>   (the lint's check needs only --allow-read)
//
//   init [--from <ref>]  the snapshot: the model as it stands, or as a git ref held it (the release
//                        the live database runs), so the first migration is what changed since
//   plan                 the changes since the snapshot and the SQL `make` would write; writes nothing
//   make <name>          the next migration, migrations/<YYYYMMDD>_<NNNN>_<name>.json (the day, its
//                        count that day, what it does), and the snapshot and the sum moved with it;
//                        nothing when a change is refused or needs a declaration
//                        (migrations_spec.cue), each named
//   rebase <ref> [name]  after merging <ref> (main) into a branch that also ran make: <ref>'s
//                        snapshot, sum and migrations taken whole, the branch's own migrations
//                        removed, and make run again, so they become one migration named after <ref>'s
//   fold <name>          the migrations through <name> deleted, once every database has run them:
//                        pgroll's ledger keeps them, and a fresh database no longer runs them
//   upgrade [--from <ref>]  a snapshot of an older format carried to this plugin's, from the model at
//                        the commit it was taken at (the last that wrote it, or <ref>)
//   check                the lint: the snapshot is the model, every file make wrote is as it wrote it,
//                        and migrations/ holds no other .json the ledger would embed
//
// The model is read from what pronto's generate writes: schema/entities.proto, .pronto/check-inputs.json,
// services/database/migrations/005_create_tables.sql and 010_machines.sql. What it decides is
// plan.js's. migrations_ledger.cue, the host's, embeds every migrations/*.json but the snapshot.
import * as rules from "./plan.js";

const PROTO = "schema/entities.proto";
const FACTS = ".pronto/check-inputs.json";
const MACHINES = "services/database/migrations/010_machines.sql";
const TABLES = "services/database/migrations/005_create_tables.sql";
const DIR = "migrations";
const SNAPSHOT = `${DIR}/${rules.SNAPSHOT_FILE}`;
const SUM = `${DIR}/migrations.sum`;
// A migration's file: its name (rules.isName) and .json.
const named = (file: string) => file.endsWith(".json") && rules.isName(file.slice(0, -5));

class Refusal extends Error {}
// The day a migration is made, on this machine's calendar: YYYYMMDD.
const today = () => {
  const d = new Date();
  return `${d.getFullYear()}${String(d.getMonth() + 1).padStart(2, "0")}${String(d.getDate()).padStart(2, "0")}`;
};
const fail = (msg: string): never => {
  throw new Refusal(msg);
};
const read = (p: string) => Deno.readTextFileSync(p);
// Whether a file is there: only its absence is false; a permission or any other error is the error.
const exists = (p: string) => {
  try {
    Deno.statSync(p);
    return true;
  } catch (e) {
    if (e instanceof Deno.errors.NotFound) return false;
    throw e;
  }
};

function run(cmd: string, args: string[]): string {
  let out;
  try {
    out = new Deno.Command(cmd, { args, stdout: "piped", stderr: "piped" }).outputSync();
  } catch (e) {
    return fail(`${cmd}: ${(e as Error).message}`);
  }
  if (!out.success) fail(`${cmd} ${args.join(" ")}: ${new TextDecoder().decode(out.stderr).trim()}`);
  return new TextDecoder().decode(out.stdout);
}

// The model as the tree holds it, or as a git ref did. A ref is read through the app's own path in
// its repository, whatever folder the app sits in. An app with no machine has no 010.
function modelAt(ref?: string) {
  if (!ref) return rules.model(read(PROTO), JSON.parse(read(FACTS)), { tables: read(TABLES), machines: exists(MACHINES) ? read(MACHINES) : "" });
  const sha = run("git", ["rev-parse", "--verify", `${ref}^{commit}`]).trim();
  const prefix = run("git", ["rev-parse", "--show-prefix"]).trim();
  const at = (p: string) => run("git", ["show", `${sha}:${prefix}${p}`]);
  const held = run("git", ["ls-tree", "-r", "--name-only", "--full-tree", sha, "--", `${prefix}${MACHINES}`]).trim();
  return rules.model(at(PROTO), JSON.parse(at(FACTS)), { tables: at(TABLES), machines: held ? at(MACHINES) : "" });
}

const files = () => exists(DIR) ? [...Deno.readDirSync(DIR)].map((e) => e.name) : [];
const migrations = () => files().filter(named).sort().map((n) => n.slice(0, -5));
// The files the sum covers: the snapshot and every migration.
const summed = () => [SNAPSHOT, ...migrations().map((n) => `${DIR}/${n}.json`)].filter(exists).map((p) => ({ name: p.slice(DIR.length + 1), text: read(p) }));
const folded = () => exists(SUM) ? rules.foldedOf(read(SUM)) : null;
const snapshotModel = () => {
  if (!exists(SNAPSHOT)) fail(`no ${SNAPSHOT}: run init (with --from the ref your live database runs, when it runs one)`);
  return rules.fromSnapshot(read(SNAPSHOT));
};
const droppedNow = () => rules.droppedBy(migrations().map((name) => ({ name, json: JSON.parse(read(`${DIR}/${name}.json`)) })));

// The sum must hold before anything is written: a hand edit is never summed again by make.
async function sound() {
  const problems = await rules.verify(exists(SUM) ? read(SUM) : "", summed());
  if (problems.length) fail(`${problems.map((p) => `${DIR}/${p}`).join("; ")}: restore what make wrote before running it again`);
}

// What the app declared for the migrations (#Migrations in migrations_spec.cue) and the names of all
// its pgroll migrations, its own included, in one evaluation of the program: read only by make and
// plan, as the lint does not evaluate the program.
function program(): { declared: Record<string, unknown>; names: string[] } {
  const declared = JSON.parse(run(Deno.env.get("CUE") ?? "cue", ["export", ".", "-e", "schemaMigrations", "--out", "json"]));
  return { declared, names: declared.names ?? [] };
}

function report(p: ReturnType<typeof rules.plan>) {
  for (const r of p.refused) console.error(`refused  ${r.at}: ${r.why}`);
  for (const n of p.needs) console.error(`needs    ${n.at}: declare schemaMigrations.${n.declare} in migrations_spec.cue: ${n.why}`);
  for (const a of p.advisories) console.log(`note     ${a.at}: ${a.why}`);
}

async function write(now: ReturnType<typeof rules.model>, foldedName: string | null) {
  Deno.mkdirSync(DIR, { recursive: true });
  Deno.writeTextFileSync(SNAPSHOT, rules.snapshot(now));
  Deno.writeTextFileSync(SUM, await rules.sum(summed(), foldedName));
}

// The next migration from the snapshot to the model, with the snapshot and the sum moved with it;
// false when the model is the snapshot. A refusal or a need writes nothing.
async function make(slug: string): Promise<boolean> {
  const now = modelAt();
  const list = rules.diff(snapshotModel(), now);
  if (!list.length) return false;
  const { declared, names: all } = program();
  const p = rules.plan(list, declared, droppedNow());
  report(p);
  if (p.refused.length || p.needs.length) fail("nothing written");
  const names = migrations();
  if (p.ops.length) {
    const last = folded();
    const name = rules.nextName(last ? [...names, last] : names, slug, today(), all);
    Deno.writeTextFileSync(`${DIR}/${name}.json`, JSON.stringify(rules.migration(p.ops), null, 2) + "\n");
    console.log(`wrote ${DIR}/${name}.json: ${p.ops.length} change${p.ops.length === 1 ? "" : "s"}, in one operation`);
  } else {
    console.log("nothing for the ledger: the replay of the emitted schema makes these changes");
  }
  await write(now, folded());
  console.log(`moved ${SNAPSHOT} and ${SUM}`);
  return true;
}

// What a git ref holds of the files make writes (the snapshot, the sum and each migration), by their
// path in the app, read through the app's own path in its repository.
function filesAt(ref: string): Map<string, string> {
  const sha = run("git", ["rev-parse", "--verify", `${ref}^{commit}`]).trim();
  const prefix = run("git", ["rev-parse", "--show-prefix"]).trim();
  const held = run("git", ["ls-tree", "-r", "--name-only", "--full-tree", sha, "--", `${prefix}${DIR}/`]).split("\n").filter(Boolean).map((p) => p.slice(prefix.length));
  const wanted = held.filter((p) => p === SNAPSHOT || p === SUM || (p.startsWith(`${DIR}/`) && named(p.slice(DIR.length + 1))));
  return new Map(wanted.map((p) => [p, run("git", ["show", `${sha}:${prefix}${p}`])]));
}

// The last commit that wrote the snapshot: the one it was taken at, unless it was edited since.
function lastWrite(): string {
  const prefix = run("git", ["rev-parse", "--show-prefix"]).trim();
  const sha = run("git", ["log", "-1", "--format=%H", "--", `:/${prefix}${SNAPSHOT}`]).trim();
  if (!sha) fail(`no commit wrote ${SNAPSHOT}: name the one it was taken at (upgrade --from <ref>)`);
  if (run("git", ["status", "--porcelain", "--", SNAPSHOT]).trim()) fail(`${SNAPSHOT} differs from the commit that last wrote it: commit it, or name the one it was taken at (upgrade --from <ref>)`);
  return sha;
}

async function main(command: string | undefined, args: string[]) {
  switch (command) {
    case "init": {
      const from = args.length === 0 ? undefined : args.length === 2 && args[0] === "--from" ? args[1] : fail("init [--from <ref>]");
      if (exists(SNAPSHOT) || exists(SUM) || migrations().length) fail(`${DIR}/ holds a snapshot, a sum or migrations: init starts an app's migrations once, and make moves them`);
      await write(modelAt(from), null);
      console.log(`wrote ${SNAPSHOT}${from ? ` (the model at ${from})` : ""} and ${SUM}`);
      break;
    }
    case "plan": {
      if (args.length) fail("plan takes no arguments");
      const list = rules.diff(snapshotModel(), modelAt());
      if (!list.length) {
        console.log("the model is the snapshot: nothing to make");
        break;
      }
      for (const c of list) console.log(`${rules.verdict(c).padEnd(8)} ${c.kind} ${rules.where(c)}`);
      const p = rules.plan(list, program().declared, droppedNow());
      report(p);
      if (p.ops.length) console.log(`\n${rules.migration(p.ops).operations[0].sql.up}`);
      break;
    }
    case "make": {
      if (args.length !== 1) fail("make <name>: what the migration does, in lowercase letters, digits and _");
      await sound();
      if (!await make(args[0])) fail("the model is the snapshot: nothing to make");
      break;
    }
    case "rebase": {
      // After a merge of <ref> (main) into a branch that also ran make: the snapshot and the sum
      // conflict, and the branch's migration may sort before one <ref> already released. Take <ref>'s
      // migrations/ whole, drop the branch's own migrations, and make again from <ref>'s snapshot, so
      // the branch's changes become one migration named after <ref>'s.
      if (args.length < 1 || args.length > 2) fail("rebase <ref> [name]: the ref merged in (main), and what the migration does (the branch's own name when omitted)");
      const [ref, given] = args;
      const theirs = filesAt(ref);
      if (!theirs.has(SNAPSHOT)) fail(`${ref} has no ${SNAPSHOT}: rebase follows a ref that took the snapshot`);
      const theirNames = [...theirs.keys()].filter((p) => p.startsWith(`${DIR}/`) && named(p.slice(DIR.length + 1))).map((p) => p.slice(DIR.length + 1, -5));
      const mine = migrations().filter((n) => !theirNames.includes(n));
      const slugs = [...new Set(mine.map((n) => rules.slugOf(n)))];
      const slug = given ?? (slugs.length === 1 ? slugs[0] : fail(mine.length ? `the branch made ${mine.join(", ")}: name the one migration they become (rebase ${ref} <name>)` : `the branch made no migration: name what the next one does (rebase ${ref} <name>), in case the model needs one`));
      for (const n of migrations()) if (!theirNames.includes(n)) Deno.removeSync(`${DIR}/${n}.json`);
      for (const [p, text] of theirs) Deno.writeTextFileSync(p, text);
      await sound();
      console.log(`took ${ref}'s ${SNAPSHOT}, ${SUM} and ${theirNames.length} migration${theirNames.length === 1 ? "" : "s"}${mine.length ? `; removed the branch's ${mine.join(", ")} (git keeps them)` : ""}`);
      try {
        if (!await make(slug)) console.log("the model is the snapshot: nothing to make");
      } catch (e) {
        if (e instanceof Refusal) fail(`${e.message}: ${ref}'s migrations are in place; declare what make names (a carry or backfill the branch's migration had), then run make ${slug}`);
        throw e;
      }
      break;
    }
    case "fold": {
      if (args.length !== 1) fail("fold <name>: the last migration every database has run");
      await sound();
      const names = migrations();
      if (!names.includes(args[0])) fail(`${args[0]}: no such migration (${names.join(", ") || "none"})`);
      const gone = names.filter((n) => n <= args[0]);
      for (const n of gone) Deno.removeSync(`${DIR}/${n}.json`);
      Deno.writeTextFileSync(SUM, await rules.sum(summed(), args[0]));
      console.log(`folded ${gone.join(", ")}: the sum keeps ${args[0]}, so the next migration still sorts after it`);
      break;
    }
    case "upgrade": {
      const from = args.length === 0 ? undefined : args.length === 2 && args[0] === "--from" ? args[1] : fail("upgrade [--from <ref>]");
      if (!exists(SNAPSHOT)) fail(`no ${SNAPSHOT}: init writes one of this plugin's format`);
      await sound();
      const ref = from ?? lastWrite();
      const up = rules.upgrade(read(SNAPSHOT), modelAt(ref));
      Deno.writeTextFileSync(SNAPSHOT, rules.snapshot(up.model));
      Deno.writeTextFileSync(SUM, await rules.sum(summed(), folded()));
      console.log(`carried ${SNAPSHOT} from format ${up.from} to ${rules.FORMAT}, from the model at ${ref}, and moved ${SUM}`);
      break;
    }
    case "check": {
      if (args.length) fail("check takes no arguments");
      const problems: string[] = [];
      const before = snapshotModel();
      problems.push(...(await rules.verify(exists(SUM) ? read(SUM) : "", summed())).map((p) => `${DIR}/${p}`));
      const names = migrations();
      for (const f of rules.strays(files())) problems.push(`${DIR}/${f}: migrations_ledger.cue embeds every .json here but the snapshot, and this is no migration's name (<YYYYMMDD>_<NNNN>_<name>.json)`);
      const list = rules.diff(before, modelAt());
      const p = rules.plan(list, {}, droppedNow());
      for (const r of p.refused) problems.push(`${r.at}: ${r.why}`);
      if (list.length && !p.refused.length) {
        problems.push(`the model moved since ${SNAPSHOT} (${list.length} change${list.length === 1 ? "" : "s"}): run \`deno run --no-config -A migrations/migrate.ts make <name>\``);
      }
      for (const x of problems) console.error(`migrations: ${x}`);
      if (problems.length) Deno.exit(1);
      console.log(`migrations: the model is the snapshot, ${names.length} migration${names.length === 1 ? "" : "s"} as made`);
      break;
    }
    default:
      fail("init [--from <ref>] | plan | make <name> | rebase <ref> [name] | fold <name> | upgrade [--from <ref>] | check");
  }
}

try {
  await main(Deno.args[0], Deno.args.slice(1));
} catch (e) {
  console.error(`migrations: ${(e as Error).message}`);
  Deno.exit(1);
}
