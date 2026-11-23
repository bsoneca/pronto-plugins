// The flags in an app's database (flags_plugin.cue's flagd.sql) on PGlite: pronto_flags.flag_on()
// answers as flagd does for the document put() wrote and the host it is served at (its default, its local
// value at hand, its accounts, a push's canary for the testers), off for a flag the document lacks or with
// no document; a test database (the marker pronto_flags.at_hand) holds the baked flags at hand's host, and
// a replay over either changes nothing else. cue comes from PATH, as the plugins tree pins it.
import { PGlite } from "npm:@electric-sql/pglite@0.3.7";

const eq = (a: unknown, b: unknown, m: string) => { if (JSON.stringify(a) !== JSON.stringify(b)) throw new Error(`${m}: expected ${JSON.stringify(b)}, got ${JSON.stringify(a)}`); };
const dec = new TextDecoder();

const SPEC = `
flags: {
  premium: {default: false, local: true, accounts: ["0b0b0b0b-0000-4000-8000-000000000001"]}
  ads: {default: true, local: false}
  banner: {default: "off", local: "on"}
  quiet: {default: false}
}
`;
const ME = "0b0b0b0b-0000-4000-8000-000000000001";
const TESTER = "0b0b0b0b-0000-4000-8000-0000000000aa";
const OTHER = "0b0b0b0b-0000-4000-8000-0000000000ff";

async function exported(spec: string, expr: string) {
  const dir = await Deno.makeTempDir();
  await Deno.writeTextFile(`${dir}/program.cue`, "package shop\n");
  const inst = await new Deno.Command(Deno.execPath(), { args: ["run", "--no-config", "--allow-read", "--allow-write", new URL("./install.ts", import.meta.url).pathname, dir] }).output();
  if (!inst.success) throw new Error(dec.decode(inst.stderr));
  await Deno.writeTextFile(`${dir}/flags_spec.cue`, `package shop\n${spec}`);
  const out = await new Deno.Command("cue", { args: ["export", `${dir}/flags_plugin.cue`, `${dir}/flags_spec.cue`, "-e", expr, "--out", "json"] }).output();
  await Deno.remove(dir, { recursive: true });
  if (!out.success) throw new Error(`cue export -e ${expr}: ${dec.decode(out.stderr)}`);
  return JSON.parse(dec.decode(out.stdout));
}

async function db(sql: string, atHand: boolean) {
  const pg = new PGlite();
  if (atHand) {
    // As an app's fixture does on a fresh database: the migration, then the marker and the fill.
    await pg.exec(sql);
    await pg.exec("INSERT INTO pronto_flags.at_hand DEFAULT VALUES ON CONFLICT DO NOTHING; SELECT pronto_flags.fill_local();");
  } else await pg.exec(sql);
  return pg;
}
const on = async (pg: PGlite, flag: string, player: string | null = null) =>
  (await pg.query<{ v: boolean }>("SELECT pronto_flags.flag_on($1, $2::uuid) AS v", [flag, player])).rows[0].v;
const value = async (pg: PGlite, flag: string, player: string | null = null) =>
  (await pg.query<{ v: unknown }>("SELECT pronto_flags.flag_value($1, $2::uuid) AS v", [flag, player])).rows[0].v;
const put = (pg: PGlite, doc: unknown, host: string) => pg.query("SELECT pronto_flags.put($1::jsonb, $2)", [JSON.stringify(doc), host]);

Deno.test("a database without a document, or without the flag, reads every flag as off", async () => {
  const pg = await db(await exported(SPEC, "flagd.sql"), false);
  eq(await on(pg, "ads"), false, "no document: a flag on by default is off");
  eq(await value(pg, "banner"), null, "no document: no value");
  await put(pg, await exported(SPEC, "flagd.document"), "bonk.example");
  eq(await on(pg, "nope"), false, "a flag the document lacks");
  await pg.close();
});

Deno.test("released: each flag's default, and its accounts' local value", async () => {
  const pg = await db(await exported(SPEC, "flagd.sql"), false);
  await put(pg, await exported(SPEC, "flagd.document"), "bonk.example");
  eq(await on(pg, "premium"), false, "premium for no one");
  eq(await on(pg, "premium", OTHER), false, "premium for another account");
  eq(await on(pg, "premium", ME), true, "premium for its account");
  eq(await on(pg, "ads", ME), true, "ads by default");
  eq(await value(pg, "banner"), "off", "a string flag's default");
  eq(await on(pg, "quiet"), false, "a flag with one value everywhere");
  await pg.close();
});

Deno.test("at hand: a test database holds the baked flags at hand's host; another holds none", async () => {
  const sql = await exported(SPEC, "flagd.sql");
  const pg = await db(sql, true);
  eq(await on(pg, "premium"), true, "premium's local value");
  eq(await on(pg, "ads"), false, "ads' local value");
  eq(await value(pg, "banner"), "on", "a string flag's local value");
  // A replay (every release replays the raw migrations) keeps the test database's copy, and still fills none elsewhere.
  await pg.exec(sql);
  eq(await on(pg, "premium"), true, "after a replay");
  await pg.close();
  const rel = await db(sql, false);
  await rel.exec(sql);
  eq((await rel.query<{ n: number }>("SELECT count(*)::int AS n FROM pronto_flags.live")).rows[0].n, 0, "a release's database holds nothing");
  await rel.close();
});

Deno.test("a push's canary: on for the testers alone, then the final document for everyone", async () => {
  const pg = await db(await exported(SPEC, "flagd.sql"), false);
  const doc = await exported(SPEC, "flagd.document");
  // As live.nu's canary-doc wrote it before PRONTO-284 (an older version may still hold one): old and new variants, the testers' test first, then the rule it had.
  const canary = structuredClone(doc);
  canary.flags.premium = {
    state: "ENABLED", variants: { ...doc.flags.premium.variants, old: false, new: true }, defaultVariant: "default",
    targeting: { if: [{ in: [{ var: "targetingKey" }, [TESTER]] }, "new", doc.flags.premium.targeting] },
  };
  canary.flags.fresh = { state: "ENABLED", variants: { old: false, new: true }, defaultVariant: "old", targeting: { if: [{ in: [{ var: "targetingKey" }, [TESTER]] }, "new", "old"] } };
  await put(pg, canary, "bonk.example");
  eq(await on(pg, "premium", TESTER), true, "the tester reads the new value");
  eq(await on(pg, "premium", OTHER), false, "another account the old one");
  eq(await on(pg, "premium", ME), true, "the flag's account its local value, as before");
  eq(await on(pg, "fresh", TESTER), true, "a new flag for the tester");
  eq(await on(pg, "fresh", OTHER), false, "a new flag off for everyone else");
  await put(pg, await exported(SPEC.replace("premium: {default: false", "premium: {default: true"), "flagd.document"), "bonk.example");
  eq(await on(pg, "premium", OTHER), true, "the final document: on for everyone");
  await pg.close();
});

Deno.test("a targeting the evaluator cannot evaluate raises, never the default; null or an unknown variant reads the default; a disabled flag reads nothing", async () => {
  const pg = await db(await exported(SPEC, "flagd.sql"), false);
  await put(pg, {
    flags: {
      odd: { state: "ENABLED", variants: { on: true, off: false }, defaultVariant: "off", targeting: { if: [{ "==": [1, 1] }, "on", "off"] } },
      gone: { state: "DISABLED", variants: { on: true }, defaultVariant: "on" },
      stray: { state: "ENABLED", variants: { on: true, off: false }, defaultVariant: "on", targeting: { if: [true, "missing", "off"] } },
      nil: { state: "ENABLED", variants: { on: true, off: false }, defaultVariant: "on", targeting: { if: [false, "off"] } },
    },
  }, "localhost");
  const refusal = async (sql: string) => { try { await pg.query(sql); } catch (e) { return (e as Error).message; } return "answered"; };
  const lacks = "pronto_flags: no operator == in this evaluator";
  eq(await refusal("SELECT pronto_flags.flag_on('odd')"), lacks, "flag_on raises on an operator it lacks");
  eq(await refusal("SELECT pronto_flags.flag_value('odd')"), lacks, "flag_value raises on it");
  eq(await refusal("SELECT pronto_flags.flag_on_strict('odd')"), lacks, "the gate's name raises on it");
  eq((await pg.query<{ v: boolean }>("SELECT pronto_flags.flag_on_strict('gone') AS v, pronto_flags.flag_on_strict('missing') AS w")).rows[0], { v: false, w: false } as never, "a disabled or missing flag is off");
  eq(await on(pg, "gone"), false, "a disabled flag");
  eq(await on(pg, "stray"), true, "a variant the document lacks: the default variant");
  eq(await on(pg, "nil"), true, "a targeting that yields null: the default variant");
  await pg.close();
});

Deno.test("only the database's owner writes the flags", async () => {
  const pg = await db(await exported(SPEC, "flagd.sql"), false);
  await pg.exec("CREATE ROLE app_user; GRANT USAGE ON SCHEMA public TO app_user; SET ROLE app_user;");
  eq(await on(pg, "ads"), false, "an app role reads a flag");
  for (const write of ["SELECT pronto_flags.put('{}'::jsonb, 'localhost')", "SELECT pronto_flags.fill_local()", "INSERT INTO pronto_flags.at_hand DEFAULT VALUES", "SELECT * FROM pronto_flags.live"]) {
    const err = await pg.exec(write).then(() => null, (e) => e);
    eq(err !== null, true, `${write} refused for an app role`);
  }
  await pg.close();
});

Deno.test("a value holding a quote or a backslash reads back as written", async () => {
  const pg = await db(await exported(`flags: x: {default: "off", local: "it's \\\\ on"}`, "flagd.sql"), true);
  eq(await value(pg, "x"), "it's \\ on", "the local value");
  await pg.close();
});

// What real flagd v0.18 answered for these rules and keys (OFREP, one run per key), pinned: the database must bucket a
// player as the page does. A flagd upgrade that moves them (v0.15 and v0.18 both did) fails here before it splits a cohort.
Deno.test("fractional buckets as flagd v0.18 does: murmur3 of the CBOR of [flagKey, targetingKey], (hash * weights) >> 32", async () => {
  const pg = await db(await exported(SPEC, "flagd.sql"), false);
  const variants = { a: "a", b: "b", c: "c" };
  const flag = (fractional: unknown) => ({ state: "ENABLED", variants, defaultVariant: "a", targeting: { fractional } });
  await put(pg, {
    flags: {
      three: flag([["a", 20], ["b", 30], ["c", 50]]),
      own: flag([{ var: "targetingKey" }, ["a", 50], ["b", 50]]),
      bare: flag([["a"], ["b"], ["c"]]),
      long: flag([["a", 1], ["b", 1]]),
      none: flag([["b", 0], ["c", 0]]),
      later: { state: "ENABLED", variants, defaultVariant: "a", targeting: { if: [{ in: [{ var: "host" }, ["elsewhere"]] }, "c", { fractional: [["b", 100], ["c", 0]] }] } },
    },
  }, "bonk.example");
  const nums = [...Array(25)].map((_, i) => `${i + 1}`);
  const keys30 = [...nums, ME, TESTER, OTHER, "5f8d3c2e-1111-4222-8333-444455556666", "é☃"];
  const keys21 = [...nums.slice(0, 20), "k".repeat(40)];
  // The page's keys are player uuids and flag_value takes a uuid, so the table of other strings goes through the rule itself.
  const raw = async (flag: string, keys: string[]) => {
    const out: string[] = [];
    for (const k of keys) {
      const r = await pg.query<{ v: unknown }>(
        "SELECT pronto_flags.rule((SELECT doc -> 'flags' -> $1::text -> 'targeting' FROM pronto_flags.live), jsonb_build_object('host', 'x', 'targetingKey', $2::text, '$flagd', jsonb_build_object('flagKey', $1::text))) AS v",
        [flag, k],
      );
      out.push(String(r.rows[0].v));
    }
    return out.join("");
  };
  eq(await raw("three", keys30), "bccaccccabcaccbbaaccccccbbaccb", "20/30/50 across 30 keys");
  eq(await raw("own", keys21), "abaaabbbbbaaaaababbaa", "a bucketing value of its own is hashed alone");
  eq(await raw("bare", keys21), "babbcaaccccacabbbbbac", "weights left out are 1 each; a 40-byte key takes CBOR's one-byte length");
  eq(await raw("long", keys21), "abaaabaaabbabbabaabaa", "a flag key of another length");
  eq(await [ME, TESTER, OTHER].reduce(async (s, p) => (await s) + await value(pg, "three", p), Promise.resolve("")), "bac", "flag_value through a player uuid: the same buckets");
  eq(await value(pg, "three"), "a", "no targetingKey reads the default variant, as flagd's TARGETING_KEY_MISSING does");
  eq(await value(pg, "none"), "a", "weights summing to 0 read the default variant");
  eq(await value(pg, "later", ME), "b", "a fractional as a branch of an if");
  eq(await value(pg, "own"), "a", "a null bucketing value reads the default variant");
  await pg.close();
});

Deno.test("a fractional rule that is malformed raises", async () => {
  const pg = await db(await exported(SPEC, "flagd.sql"), false);
  const bad = (fractional: unknown) => ({ state: "ENABLED", variants: { a: 1 }, defaultVariant: "a", targeting: { fractional } });
  await put(pg, { flags: { empty: bad([]), notlist: bad([["a", 1], "b"]), wide: bad([["a", 2147483647], ["a", 1]]), num: bad([{ var: "x" }, ["a", 1]]), text: bad([["a", "5"]]), half: bad([["a", 1.5]]), huge: bad([["a", 1e30]]) } }, "localhost");
  const refusal = async (f: string) => { try { await pg.query("SELECT pronto_flags.flag_on($1, $2::uuid)", [f, ME]); } catch (e) { return (e as Error).message; } return "answered"; };
  eq(await refusal("empty"), "pronto_flags: a fractional rule needs a distribution: []", "no distribution");
  eq(await refusal("notlist"), 'pronto_flags: a fractional distribution is [variant, weight]: "b"', "an element that is no pair");
  eq(await refusal("wide"), "pronto_flags: the weights of a fractional rule sum past 2147483647", "weights past the limit");
  const whole = "pronto_flags: a fractional weight is a whole number up to 2147483647: ";
  eq(await refusal("text"), `${whole}"5"`, "a weight that is a string");
  eq(await refusal("half"), `${whole}1.5`, "a weight that is not whole");
  eq(await refusal("huge"), `${whole}1000000000000000000000000000000`, "a weight past the limit");
  eq(await refusal("num"), "answered", "a bucketing value the context lacks reads the default variant");
  await pg.close();
});
