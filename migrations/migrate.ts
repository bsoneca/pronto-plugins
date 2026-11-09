// pronto-migrations' driver (migrations/README.md in pronto-plugins): run from the app's folder.
//
//   deno run --no-config --allow-read --allow-write --allow-run --allow-env migrations/migrate.ts <command>
//
//   init [--from <ref>]  the snapshot: the model as it stands, or as a git ref held it (the release
//                        the live database runs), so the first migration is what changed since
//   plan                 the changes since the snapshot and the SQL `make` would write; writes nothing
//   make <name>          the next migration, migrations/<YYYYMMDD>_<NNNN>_<name>.json (the day, its
//                        count that day, what it does), and the snapshot, the
//                        sum and the ledger moved with it; nothing when a change is refused or needs
//                        a declaration (migrations_spec.cue), each named
//   fold <name>          the migrations through <name> deleted, once every database has run them:
//                        pgroll's ledger keeps them, and a fresh database no longer runs them
//   check                the lint: the snapshot is the model, every file make wrote is as it wrote it,
//                        and the ledger lists the migrations
//
// The model is read from what pronto's generate writes: schema/entities.proto, .pronto/check-inputs.json
// and services/database/migrations/010_machines.sql. What it decides is plan.js's.
import * as rules from "./plan.js";

const PROTO = "schema/entities.proto";
const FACTS = ".pronto/check-inputs.json";
const MACHINES = "services/database/migrations/010_machines.sql";
const DIR = "migrations";
const SNAPSHOT = `${DIR}/snapshot.json`;
const SUM = `${DIR}/migrations.sum`;
const LEDGER = "migrations_ledger.cue";
const NAMED = /^\d{8}_\d{4}_[a-z][a-z0-9_]*\.json$/;

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
const exists = (p: string) => {
  try {
    Deno.statSync(p);
    return true;
  } catch {
    return false;
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
// its repository, whatever folder the app sits in.
function modelAt(ref?: string) {
  if (!ref) return rules.model(read(PROTO), JSON.parse(read(FACTS)), exists(MACHINES) ? read(MACHINES) : "");
  const sha = run("git", ["rev-parse", "--verify", `${ref}^{commit}`]).trim();
  const prefix = run("git", ["rev-parse", "--show-prefix"]).trim();
  const at = (p: string) => run("git", ["show", `${sha}:${prefix}${p}`]);
  const held = run("git", ["ls-tree", "-r", "--name-only", "--full-tree", sha, "--", `${prefix}${MACHINES}`]).trim();
  return rules.model(at(PROTO), JSON.parse(at(FACTS)), held ? at(MACHINES) : "");
}

const migrations = () => exists(DIR) ? [...Deno.readDirSync(DIR)].map((e) => e.name).filter((n) => NAMED.test(n)).sort().map((n) => n.slice(0, -5)) : [];
// The files the sum covers: the snapshot and every migration.
const summed = () => [SNAPSHOT, ...migrations().map((n) => `${DIR}/${n}.json`)].filter(exists).map((p) => ({ name: p.slice(DIR.length + 1), text: read(p) }));
const folded = () => exists(SUM) ? rules.foldedOf(read(SUM)) : null;
const pkg = () => read("program.cue").match(/^package\s+([a-z][a-z0-9_]*)\s*$/m)?.[1] ?? fail("program.cue names no package");
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

async function write(now: ReturnType<typeof rules.model>, names: string[], pkgName: string, foldedName: string | null) {
  Deno.mkdirSync(DIR, { recursive: true });
  Deno.writeTextFileSync(SNAPSHOT, rules.snapshot(now));
  Deno.writeTextFileSync(SUM, await rules.sum(summed(), foldedName));
  Deno.writeTextFileSync(LEDGER, rules.ledger(pkgName, names));
}

async function main(command: string | undefined, args: string[]) {
  switch (command) {
    case "init": {
      const from = args.length === 0 ? undefined : args.length === 2 && args[0] === "--from" ? args[1] : fail("init [--from <ref>]");
      if (exists(SNAPSHOT) || exists(SUM) || migrations().length) fail(`${DIR}/ holds a snapshot, a sum or migrations: init starts an app's migrations once, and make moves them`);
      const pkgName = pkg();
      await write(modelAt(from), [], pkgName, null);
      console.log(`wrote ${SNAPSHOT}${from ? ` (the model at ${from})` : ""}, ${SUM} and ${LEDGER}`);
      break;
    }
    case "plan": {
      if (args.length) fail("plan takes no arguments");
      const list = rules.diff(snapshotModel(), modelAt());
      for (const c of list) console.log(`${(rules.verdicts as Record<string, string>)[c.kind].padEnd(8)} ${c.kind} ${rules.where(c)}`);
      const p = rules.plan(list, program().declared, droppedNow());
      report(p);
      if (p.ops.length) console.log(`\n${rules.migration(p.ops).operations[0].sql.up}`);
      if (!list.length) console.log("the model is the snapshot: nothing to make");
      break;
    }
    case "make": {
      if (args.length !== 1) fail("make <name>: what the migration does, in lowercase letters, digits and _");
      await sound();
      const pkgName = pkg();
      const now = modelAt();
      const list = rules.diff(snapshotModel(), now);
      if (!list.length) fail("the model is the snapshot: nothing to make");
      const { declared, names: all } = program();
      const p = rules.plan(list, declared, droppedNow());
      report(p);
      if (p.refused.length || p.needs.length) fail("nothing written");
      const names = migrations();
      if (p.ops.length) {
        const last = folded();
        const name = rules.nextName(last ? [...names, last] : names, args[0], today(), all);
        Deno.writeTextFileSync(`${DIR}/${name}.json`, JSON.stringify(rules.migration(p.ops), null, 2) + "\n");
        names.push(name);
        console.log(`wrote ${DIR}/${name}.json: ${p.ops.length} change${p.ops.length === 1 ? "" : "s"}, in one operation`);
      } else {
        console.log("nothing for the ledger: the replay of the emitted schema makes these changes");
      }
      await write(now, names, pkgName, folded());
      console.log(`moved ${SNAPSHOT}, ${SUM} and ${LEDGER}`);
      break;
    }
    case "fold": {
      if (args.length !== 1) fail("fold <name>: the last migration every database has run");
      await sound();
      const names = migrations();
      if (!names.includes(args[0])) fail(`${args[0]}: no such migration (${names.join(", ") || "none"})`);
      const pkgName = pkg();
      const gone = names.filter((n) => n <= args[0]);
      for (const n of gone) Deno.removeSync(`${DIR}/${n}.json`);
      Deno.writeTextFileSync(SUM, await rules.sum(summed(), args[0]));
      Deno.writeTextFileSync(LEDGER, rules.ledger(pkgName, names.filter((n) => n > args[0])));
      console.log(`folded ${gone.join(", ")}: the sum keeps ${args[0]}, so the next migration still sorts after it`);
      break;
    }
    case "check": {
      if (args.length) fail("check takes no arguments");
      const problems: string[] = [];
      const before = snapshotModel();
      problems.push(...(await rules.verify(exists(SUM) ? read(SUM) : "", summed())).map((p) => `${DIR}/${p}`));
      const names = migrations();
      if (!exists(LEDGER) || read(LEDGER) !== rules.ledger(pkg(), names)) problems.push(`${LEDGER}: not what make writes for ${names.length} migration${names.length === 1 ? "" : "s"}`);
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
      fail("init [--from <ref>] | plan | make <name> | fold <name> | check");
  }
}

try {
  await main(Deno.args[0], Deno.args.slice(1));
} catch (e) {
  console.error(`migrate: ${(e as Error).message}`);
  Deno.exit(1);
}
