// pronto-alerts' driver (alerts/subscriber.ts) run once against a fake Pub/Sub pull endpoint and a fake phone, both on
// localhost, with an inbox folder of its own: what the inbox held when each acknowledge arrived, which calls came in
// what order, and what the phone was told. No network and no credentials: the token is a function that returns a word.
import { exists, pollOnce } from '../../alerts/subscriber.ts';

// A message as :pull returns it: the incident as Cloud Monitoring publishes it, in base64.
export const message = (id, incident) => ({ messageId: id, data: btoa(JSON.stringify(incident)) });
export const garbage = (id) => ({ messageId: id, data: btoa('not an incident') });

// The made-up labels of the payload's resource, metric, condition query, documentation and summary: any in a text is a leak.
export const leaks = (text) => ['RESOURCE-LABEL-MARKER', 'RESOURCE-NAME-MARKER', 'METRIC-LABEL-MARKER', 'FILTER-MARKER', 'DOCUMENTATION-MARKER', 'SUMMARY-MARKER'].filter((m) => text.includes(m));

// `batches` are the pulls' answers in order (each a list of messages); `refuseFirst` answers the first call 401.
export async function drain({ batches, push = ['CRITICAL'], phone = true, refuseFirst = false, passes, fail, now, old }) {
  const dir = Deno.makeTempDirSync({ prefix: 'alerts-' });
  const calls = [], inboxAtAck = [], told = [], tokens = [];
  const inboxPath = `${dir}/my-app.jsonl`;
  const lines = () => { try { return Deno.readTextFileSync(inboxPath).split('\n').filter(Boolean).length; } catch { return 0; } };
  let pulls = 0, refused = false;
  const server = Deno.serve({ port: 0, onListen() {}, signal: undefined }, async (req) => {
    const u = new URL(req.url);
    if (u.pathname.startsWith('/phone/')) { told.push({ path: u.pathname, body: await req.text(), priority: req.headers.get('priority') }); return new Response('ok'); }
    if (fail === 403) { calls.push('403'); return new Response('denied', { status: 403 }); }
    if (refuseFirst && !refused) { refused = true; calls.push('401'); return new Response('no', { status: 401 }); }
    const auth = req.headers.get('authorization');
    const body = await req.json();
    if (u.pathname.endsWith(':pull')) {
      calls.push(`pull ${auth}`);
      const answer = (batches[pulls++] ?? []).map((m) => ({ ackId: `ack-${m.id}`, message: m.garbage ? garbage(m.id) : message(m.id, m.incident) }));
      return Response.json(answer.length ? { receivedMessages: answer } : {});
    }
    calls.push(`ack ${body.ackIds.join(',')}`);
    inboxAtAck.push(lines());
    return Response.json({});
  });
  const base = fail === 'network' ? 'http://localhost:1' : `http://localhost:${server.addr.port}`;
  const errors = [];
  if (old) {
    // An inbox left by an earlier day, and a file for that day already there: rotation must keep both.
    Deno.writeTextFileSync(`${dir}/my-app.jsonl`, old.current);
    Deno.utimeSync(`${dir}/my-app.jsonl`, new Date(`${old.day}T12:00:00Z`), new Date(`${old.day}T12:00:00Z`));
    if (old.rotated !== undefined) Deno.writeTextFileSync(`${dir}/my-app.${old.day}.jsonl`, old.rotated);
  }
  let word = 0;
  const results = [];
  try {
    for (let i = 0; i < (passes ?? batches.length); i++) {
      try {
      results.push(await pollOnce({
        api: base,
        sub: { app: 'my-app', project: 'my-project-1', subscription: 'alerts-my-app-inbox', push, ntfy: phone ? { url: `${base}/phone`, topic: 'my-app-alerts' } : undefined },
        token: (refresh) => { if (refresh || !word) tokens.push(refresh ? 'refresh' : 'first'); word = refresh ? word + 1 : word || 1; return Promise.resolve(`word${word}`); },
        dir,
        ntfyToken: () => Promise.resolve(undefined),
        say: () => {},
        now: now ? () => new Date(now) : undefined,
        timeoutMs: 3000,
      }));
      } catch (e) { errors.push(e.message); }
    }
  } finally {
    await server.shutdown();
  }
  const text = (() => { try { return Deno.readTextFileSync(inboxPath); } catch { return ''; } })();
  const heartbeat = (() => { try { return /^\d{4}-\d\d-\d\dT/.test(Deno.readTextFileSync(`${dir}/my-app.heartbeat`)); } catch { return false; } })();
  const files = Object.fromEntries([...Deno.readDirSync(dir)].map((f) => [f.name, Deno.readTextFileSync(`${dir}/${f.name}`)]));
  Deno.removeSync(dir, { recursive: true });
  return { errors, files, results, calls, inboxAtAck, told, tokens, inbox: text.split('\n').filter(Boolean).map((l) => JSON.parse(l)), raw: text, heartbeat };
}

// `exists` on a path below a file (NotADirectory) or below a directory nobody may enter (a permission error): the first is missing, the second is
// not, and is said.
export function existence() {
  const dir = Deno.makeTempDirSync({ prefix: 'alerts-exists-' });
  Deno.writeTextFileSync(`${dir}/file`, 'x');
  Deno.mkdirSync(`${dir}/locked`);
  Deno.writeTextFileSync(`${dir}/locked/in`, 'x');
  Deno.chmodSync(`${dir}/locked`, 0o000);
  let said = null;
  try { exists(`${dir}/locked/in`); } catch (e) { said = e.name; }
  Deno.chmodSync(`${dir}/locked`, 0o700);
  const r = { there: exists(`${dir}/file`), absent: exists(`${dir}/none`), belowFile: exists(`${dir}/file/x`), said };
  Deno.removeSync(dir, { recursive: true });
  return r;
}
