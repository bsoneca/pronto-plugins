// Two runs owned by one process at once (rehearse's stacks and its Premium lane) each hold a pending ledger entry of their own:
// the first to be named must not take the second's away, or the second fails with "No such file or directory" (release-cron,
// 2026-11-21, "the rehearsal gave no verdict (exit 3)").
import { strict as assert } from "node:assert";

Deno.test("two concurrent owned runs of one process both finish", { ignore: Deno.build.os !== "darwin" }, async () => {
  const pool = await Deno.makeTempDir({ prefix: "slot-pending-" });
  Deno.env.set("STACK_POOL", pool);
  try {
    const { ownRun } = await import(`../slot.ts?pool=${pool}`);
    for (let round = 0; round < 5; round++) {
      const runs = await Promise.all([1, 2, 3].map(() => ownRun(["sleep", "0.2"], { what: "pending test" })));
      for (const r of runs) assert.equal(r.code, 0);
    }
    const left = [...Deno.readDirSync(`${pool}/runs`)].map((e) => e.name);
    assert.deepEqual(left, [], "no ledger entry is left behind");
  } finally {
    await Deno.remove(pool, { recursive: true }).catch(() => {});
  }
});
