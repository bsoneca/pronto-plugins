// pronto-api's spike (docs/pronto-api.md in pronto, PRONTO-289): one Deno service that loads a
// descriptor set at run time into a protobuf-es registry, with no generated stubs, and serves its
// methods over native gRPC, Connect (and gRPC-Web) and a REST route table, all on one port.
//
// What it settles, measured by tests/unit/api.cue:
// - connect-es serves a service built purely from a runtime descriptor (registry.getService);
// - Deno takes h2c: node:http2's server (Deno 2.9) answers gRPC with its grpc-status trailer, and
//   HTTP/1.1 on the same port goes to node:http, told apart by the HTTP/2 preface.
// Every method answers only while the flag `api_export` is on (`flag`); off, gRPC and Connect say
// unimplemented and REST 404, as if the API were not there.
import { createFileRegistry, type DescMethod, type DescService, fromBinary, fromJson, type JsonValue, toJson } from "npm:@bufbuild/protobuf@2.10.1";
import { FileDescriptorSetSchema } from "npm:@bufbuild/protobuf@2.10.1/wkt";
import { Code, ConnectError, type ConnectRouter } from "npm:@connectrpc/connect@2.1.0";
import { connectNodeAdapter } from "npm:@connectrpc/connect-node@2.1.0";
import * as http from "node:http";
import * as http2 from "node:http2";
import * as net from "node:net";

/** A REST route: an HTTP method and a path whose `{field}` segments fill the request's fields. */
export interface Route { method: "GET" | "POST" | "PUT" | "PATCH" | "DELETE"; path: string; rpc: string }
// deno-lint-ignore no-explicit-any
export type Handler = (req: any) => any;
/** Each service's methods by their local name (lowerCamelCase, as connect-es calls them). */
export type Impl = Record<string, Record<string, Handler>>;
export interface Options {
  descriptors: Uint8Array; // a FileDescriptorSet, binary
  routes: Route[];
  impl: Impl;
  flag: () => Promise<boolean>; // api_export, asked per call
  port?: number;
  hostname?: string;
}

// The methods of every service the impl names, from the registry: a service or method the
// descriptor set lacks fails here, at start, not on the first call.
function methodsOf(descriptors: Uint8Array, impl: Impl): { services: [DescService, Record<string, Handler>][]; byRpc: Map<string, [DescMethod, Handler]> } {
  const registry = createFileRegistry(fromBinary(FileDescriptorSetSchema, descriptors));
  const services: [DescService, Record<string, Handler>][] = [];
  const byRpc = new Map<string, [DescMethod, Handler]>();
  for (const [name, fns] of Object.entries(impl)) {
    const svc = registry.getService(name);
    if (!svc) throw new Error(`no service ${name} in the descriptor set`);
    for (const fn of Object.keys(fns)) if (!svc.methods.some((m) => m.localName === fn)) throw new Error(`no method ${fn} in ${name}`);
    for (const m of svc.methods) if (fns[m.localName]) byRpc.set(`${name}/${m.name}`, [m, fns[m.localName]]);
    services.push([svc, fns]);
  }
  return { services, byRpc };
}

const off = () => new ConnectError("api_export is off", Code.Unimplemented);

/** A route's path as a pattern: `/api/v1/players/{id}` matches `/api/v1/players/p1`, id = "p1". */
export function matchRoute(routes: Route[], method: string, pathname: string): { route: Route; params: Record<string, string> } | null {
  for (const route of routes) {
    if (route.method !== method) continue;
    const want = route.path.split("/"), got = pathname.split("/");
    if (want.length !== got.length) continue;
    const params: Record<string, string> = {};
    if (want.every((w, i) => {
      const m = /^\{(\w+)\}$/.exec(w);
      if (m) return got[i] !== "" && ((params[m[1]] = decodeURIComponent(got[i])), true);
      return w === got[i];
    })) return { route, params };
  }
  return null;
}

// Connect's codes as HTTP statuses (connect.build/docs/protocol#error-codes), for REST.
const httpOf: Partial<Record<Code, number>> = {
  [Code.InvalidArgument]: 400, [Code.Unauthenticated]: 401, [Code.PermissionDenied]: 403, [Code.NotFound]: 404,
  [Code.AlreadyExists]: 409, [Code.Aborted]: 409, [Code.FailedPrecondition]: 412, [Code.ResourceExhausted]: 429,
  [Code.Unimplemented]: 501, [Code.Unavailable]: 503, [Code.DeadlineExceeded]: 504,
};

async function bodyOf(req: http.IncomingMessage | http2.Http2ServerRequest): Promise<string> {
  let text = "";
  const dec = new TextDecoder();
  for await (const c of req) text += typeof c === "string" ? c : dec.decode(c, { stream: true });
  return text + dec.decode();
}

/** Starts the service; `close` stops it and every connection it holds. */
export async function serve(o: Options): Promise<{ port: number; close: () => Promise<void> }> {
  const { services, byRpc } = methodsOf(o.descriptors, o.impl);
  for (const r of o.routes) if (!byRpc.has(r.rpc)) throw new Error(`route ${r.method} ${r.path}: no method ${r.rpc}`);
  const gated = (fn: Handler): Handler => async (req) => {
    if (!(await o.flag())) throw off();
    return await fn(req);
  };
  const connect = connectNodeAdapter({
    routes(router: ConnectRouter) {
      // deno-lint-ignore no-explicit-any
      for (const [svc, fns] of services) router.service(svc, Object.fromEntries(Object.entries(fns).map(([k, f]) => [k, gated(f)])) as any);
    },
  });

  async function rest(req: http.IncomingMessage | http2.Http2ServerRequest, res: http.ServerResponse | http2.Http2ServerResponse, hit: { route: Route; params: Record<string, string> }, query: URLSearchParams) {
    const reply = (status: number, body: unknown) => {
      res.writeHead(status, { "content-type": "application/json" });
      res.end(JSON.stringify(body));
    };
    if (!(await o.flag())) return reply(404, { code: "not_found" });
    const [method, fn] = byRpc.get(hit.route.rpc)!;
    let input;
    try {
      const text = req.method === "GET" || req.method === "DELETE" ? "" : await bodyOf(req);
      const json = { ...Object.fromEntries(query), ...(text ? JSON.parse(text) : {}), ...hit.params } as JsonValue;
      input = fromJson(method.input, json);
    } catch (e) {
      return reply(400, { code: "invalid_argument", message: String((e as Error).message ?? e) });
    }
    try {
      const out = await fn(input);
      // deno-lint-ignore no-explicit-any
      reply(200, toJson(method.output, out?.$typeName ? out : fromJson(method.output, out as any)));
    } catch (e) {
      // As connect-es does: an error the method did not mean is internal, its message kept back.
      const err = e instanceof ConnectError ? e : new ConnectError("internal error", Code.Internal);
      reply(httpOf[err.code] ?? 500, { code: Code[err.code].replace(/[A-Z]/g, (c, i) => (i ? "_" : "") + c.toLowerCase()), message: err.rawMessage });
    }
  }

  const handler = (req: http.IncomingMessage | http2.Http2ServerRequest, res: http.ServerResponse | http2.Http2ServerResponse) => {
    const url = new URL(req.url ?? "/", "http://api");
    const hit = matchRoute(o.routes, req.method ?? "", url.pathname);
    if (hit) return void rest(req, res, hit, url.searchParams);
    // deno-lint-ignore no-explicit-any
    connect(req as any, res as any);
  };
  const h2 = http2.createServer(handler);
  const h1 = http.createServer(handler);
  const sockets = new Set<net.Socket>();
  // One port: an HTTP/2 connection opens with "PRI * HTTP/2.0" (h2c with prior knowledge, as
  // gRPC and Cloud Run's end-to-end HTTP/2 send it); anything else is HTTP/1.1.
  const server = net.createServer((sock) => {
    sockets.add(sock);
    sock.once("close", () => sockets.delete(sock));
    sock.once("data", (buf: Uint8Array) => {
      sock.pause();
      sock.unshift(buf);
      (new TextDecoder().decode(buf.subarray(0, 3)) === "PRI" ? h2 : h1).emit("connection", sock);
      sock.resume();
    });
  });
  await new Promise<void>((ok) => server.listen(o.port ?? 0, o.hostname ?? "127.0.0.1", ok));
  const port = (server.address() as net.AddressInfo).port;
  return {
    port,
    close: () =>
      new Promise<void>((ok) => {
        for (const s of sockets) s.destroy();
        h1.close();
        h2.close();
        server.close(() => ok());
      }),
  };
}

/** `api_export` as flagd answers it over OFREP at `flagsAt` (an origin); off when it cannot say. */
export function ofrepFlag(flagsAt: string, key = "api_export", fetcher: typeof fetch = fetch): () => Promise<boolean> {
  return async () => {
    try {
      const res = await fetcher(`${flagsAt.replace(/\/$/, "")}/ofrep/v1/evaluate/flags/${encodeURIComponent(key)}`, {
        method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ context: {} }), signal: AbortSignal.timeout(2_000),
      });
      if (!res.ok) {
        await res.body?.cancel();
        return false;
      }
      return (await res.json() as { value?: unknown }).value === true;
    } catch {
      return false;
    }
  };
}
