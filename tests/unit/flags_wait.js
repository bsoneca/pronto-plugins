// pronto-flags' wait for pickup (flags/live.nu `await-live`), run in nu against a stub of OFREP (FLAGS_OFREP_CMD): a flagd
// that says the old value until its n-th answer and the new one after, as a ConfigMap mount that catches up late.
const here = new URL('../../', import.meta.url).pathname;
const dec = new TextDecoder();

/** Waits for `flag` to read `to` (it read `from`), asking `pods` flagds that each pick the new value up at their own
 * answer: pod i after `pickup + i` answers in all; `pickup` null is a flagd that never does, `stuck` is the last pod alone never, `silent` is the last pod answering no value at all. Gives up after `limitSec`.
 * Says whether the wait returned, its error, how many answers were asked, and how long it took in seconds. */
export async function wait({ flag = 'capture_fights', from = false, to = true, pods = 1, pickup = 0, limitSec = 1, client = true, stuck = false, silent = false }) {
  const dir = await Deno.makeTempDir({ prefix: 'pronto-flags-wait-' });
  try {
    const count = `${dir}/count`;
    await Deno.writeTextFile(count, '0');
    const stub = `${dir}/ofrep.sh`;
    // One line for each pod; pod i has the new value from answer round pickup + i (one round per poll, each pod once).
    await Deno.writeTextFile(stub, `#!/bin/sh
n=$(cat "${count}"); echo $((n + 1)) > "${count}"
i=0
while [ $i -lt ${pods} ]; do
  if [ "${silent}" = "true" ] && [ $i -eq $((${pods} - 1)) ]; then echo '{}'; elif [ "${pickup}" != "null" ] && { [ "${stuck}" != "true" ] || [ $i -lt $((${pods} - 1)) ]; } && [ $n -ge $((${pickup === null ? 0 : pickup} + i)) ]; then echo '{"value": ${JSON.stringify(to)}}'; else echo '{"value": ${JSON.stringify(from)}}'; fi
  i=$((i + 1))
done
`);
    await Deno.chmod(stub, 0o755);
    const script = `use ${JSON.stringify(`${here}flags/live.nu`)} await-live
let at = {site: "https://shop.example"}
let want = [{flag: ${JSON.stringify(flag)}, new: ${JSON.stringify(to)}, client: ${client}}]
let t = (date now)
let r = (try { await-live $at $want; {ok: true, err: ""} } catch {|e| {ok: false, err: $e.msg} })
{ok: $r.ok, err: $r.err, secs: (((date now) - $t) / 1sec)} | to json -r | print`;
    const t = Date.now();
    const out = await new Deno.Command(`${here}saytw`, {
      args: ['--script', 'tools.nu', 'nu', '-c', script], cwd: here, stdout: 'piped', stderr: 'piped',
      env: { FLAGS_OFREP_CMD: stub, FLAGS_POLL_SEC: '0.05', FLAGS_WAIT_SEC: String(limitSec) },
    }).output();
    const reply = JSON.parse(dec.decode(out.stdout).trim().split('\n').pop());
    return { ok: reply.ok, err: reply.err, asked: Number(await Deno.readTextFile(count)), late: reply.secs >= limitSec - 0.01, ms: Date.now() - t };
  } finally { await Deno.remove(dir, { recursive: true }); }
}
