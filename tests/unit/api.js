// pronto-api's spike (api/service.ts) on a port of its own: a descriptor set given as its JSON
// encoding, turned to the binary the service loads; one Ping method whose answer says what it was
// asked; and the same call made by each client a reader would use, measured by what came back.
import { createFileRegistry, fromJson, toBinary } from 'npm:@bufbuild/protobuf@2.10.1';
import { FileDescriptorSetSchema } from 'npm:@bufbuild/protobuf@2.10.1/wkt';
import { createClient } from 'npm:@connectrpc/connect@2.1.0';
import { createConnectTransport, createGrpcTransport, createGrpcWebTransport, Http2SessionManager } from 'npm:@connectrpc/connect-node@2.1.0';
import { matchRoute, ofrepFlag, serve } from '../../api/service.ts';

export { matchRoute };

const impl = {
  'spike.v1.PingService': {
    ping(req) {
      if (req.text === 'boom') throw new Error('boom');
      return { text: `pong:${req.text}`, count: req.text.length + req.times };
    },
  },
};

/** The descriptor set's binary, from its JSON encoding. */
export function descriptors(set) {
  return toBinary(FileDescriptorSetSchema, fromJson(FileDescriptorSetSchema, set));
}

/** The service started on `set` and `routes`, its impl naming `names` (each service's methods);
 * "started" when it did (a start that throws fails the step, its message checked). */
export async function starts(set, routes, names) {
  const fns = Object.fromEntries(Object.entries(names).map(([svc, ms]) => [svc, Object.fromEntries(ms.map((m) => [m, impl['spike.v1.PingService'].ping]))]));
  const s = await serve({ descriptors: descriptors(set), routes, impl: fns, flag: () => Promise.resolve(true) });
  await s.close();
  return 'started';
}

const plain = (m) => (m && typeof m === 'object' ? Object.fromEntries(Object.entries(m).filter(([k]) => k !== '$typeName')) : m);
const codeOf = (e) => (e?.code === undefined ? String(e) : e.code);

/** One Ping `req` made over native gRPC (h2c), Connect over HTTP/2 and over HTTP/1.1 (a plain
 * fetch of Connect's JSON), gRPC-Web over HTTP/1.1, and REST at `rest` (a path and query, GET), with api_export `on`. */
export async function called(set, routes, req, rest, on = true) {
  const s = await serve({ descriptors: descriptors(set), routes, impl, flag: () => Promise.resolve(on) });
  const base = `http://127.0.0.1:${s.port}`;
  const svc = createFileRegistry(fromJson(FileDescriptorSetSchema, set)).getService('spike.v1.PingService');
  const sessions = [];
  const client = (transport) => createClient(svc, transport);
  const call = async (c) => {
    try {
      return plain(await c.ping(req, { timeoutMs: 5000 }));
    } catch (e) {
      return { error: codeOf(e) };
    }
  };
  try {
    const h2 = () => {
      const m = new Http2SessionManager(base);
      sessions.push(m);
      return m;
    };
    const grpc = await call(client(createGrpcTransport({ baseUrl: base, sessionManager: h2() })));
    const connectH2 = await call(client(createConnectTransport({ baseUrl: base, httpVersion: '2', sessionManager: h2() })));
    const grpcWeb = await call(client(createGrpcWebTransport({ baseUrl: base, httpVersion: '1.1' })));
    const r1 = await fetch(`${base}/spike.v1.PingService/Ping`, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(req) });
    const connectH1 = { status: r1.status, body: await r1.json() };
    const r2 = await fetch(`${base}${rest}`);
    const restOut = { status: r2.status, body: await r2.json() };
    return { grpc, connectH2, grpcWeb, connectH1, rest: restOut };
  } finally {
    for (const m of sessions) m.abort();
    await s.close();
  }
}

/** api_export as ofrepFlag reads it from a stand-in flagd answering `answer` (a status and a body). */
export async function flagRead(answer) {
  const fetcher = () => Promise.resolve(new Response(JSON.stringify(answer.body), { status: answer.status }));
  return await ofrepFlag('http://flagd', 'api_export', fetcher)();
}
