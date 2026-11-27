// pronto-alerts' driver (alerts/subscriber.ts) run once against a fake Pub/Sub pull endpoint and a fake phone, both on
// localhost, with an inbox folder of its own: what the inbox held when each acknowledge arrived, which calls came in
// what order, and what the phone was told. No network and no credentials: the token is a function that returns a word.
import { pollOnce } from '../../alerts/subscriber.ts';

// A message as :pull returns it: the incident as Cloud Monitoring publishes it, in base64.
export const message = (id, incident) => ({ messageId: id, data: btoa(JSON.stringify(incident)) });
export const garbage = (id) => ({ messageId: id, data: btoa('not an incident') });

// The made-up labels of the payload's resource, metric, condition query, documentation and summary: any in a text is a leak.
export const leaks = (text) => ['RESOURCE-LABEL-MARKER', 'RESOURCE-NAME-MARKER', 'METRIC-LABEL-MARKER', 'FILTER-MARKER', 'DOCUMENTATION-MARKER', 'SUMMARY-MARKER'].filter((m) => text.includes(m));

// `batches` are the pulls' answers in order (each a list of messages); `refuseFirst` answers the first call 401.
export async function drain({ batches, push = ['CRITICAL'], phone = true, refuseFirst = false, passes }) {
  const dir = Deno.makeTempDirSync({ prefix: 'alerts-' });
  const calls = [], inboxAtAck = [], told = [], tokens = [];
  const inboxPath = `${dir}/my-app.jsonl`;
  const lines = () => { try { return Deno.readTextFileSync(inboxPath).split('\n').filter(Boolean).length; } catch { return 0; } };
  let pulls = 0, refused = false;
  const server = Deno.serve({ port: 0, onListen() {}, signal: undefined }, async (req) => {
    const u = new URL(req.url);
    if (u.pathname.startsWith('/phone/')) { told.push({ path: u.pathname, body: await req.text(), priority: req.headers.get('priority') }); return new Response('ok'); }
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
  const base = `http://localhost:${server.addr.port}`;
  let word = 0;
  const results = [];
  try {
    for (let i = 0; i < (passes ?? batches.length); i++) {
      results.push(await pollOnce({
        api: base,
        sub: { app: 'my-app', project: 'my-project-1', subscription: 'alerts-my-app-inbox', push, ntfy: phone ? { url: `${base}/phone`, topic: 'my-app-alerts' } : undefined },
        token: (refresh) => { if (refresh || !word) tokens.push(refresh ? 'refresh' : 'first'); word = refresh ? word + 1 : word || 1; return Promise.resolve(`word${word}`); },
        dir,
        ntfyToken: () => Promise.resolve(undefined),
        say: () => {},
      }));
    }
  } finally {
    await server.shutdown();
  }
  const text = (() => { try { return Deno.readTextFileSync(inboxPath); } catch { return ''; } })();
  const heartbeat = (() => { try { return /^\d{4}-\d\d-\d\dT/.test(Deno.readTextFileSync(`${dir}/heartbeat`)); } catch { return false; } })();
  Deno.removeSync(dir, { recursive: true });
  return { results, calls, inboxAtAck, told, tokens, inbox: text.split('\n').filter(Boolean).map((l) => JSON.parse(l)), raw: text, heartbeat };
}
