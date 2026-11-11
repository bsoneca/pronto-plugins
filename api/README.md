# api (spike)

pronto-api's spike (PRONTO-289; the design is pronto's `docs/pronto-api.md`): one Deno service,
[`service.ts`](service.ts), that loads a descriptor set at run time into a protobuf-es registry, with
no generated stubs, and serves its methods over native gRPC, Connect (and gRPC-Web) and a REST route
table, all on one port. Every method answers only while the flag `api_export` is on, read from
flagd over OFREP (`ofrepFlag`); off, gRPC and Connect say `unimplemented` and REST `404`. Nothing
installs it yet: the generator, the plugin and the apps come in PRONTO-313 and after.

What it settled, each measured by a case of [`tests/unit/api.cue`](../tests/unit/api.cue):

- **connect-es serves a service built purely from a runtime descriptor.** `createFileRegistry` over
  a `FileDescriptorSet` gives a `DescService` that `router.service` takes like a generated one;
  requests arrive as messages of the registry's types and answers may be plain objects. The fallback
  (generated TypeScript stubs per app) is not needed.
- **Deno takes h2c, with trailers, on Deno 2.9.** `node:http2`'s server answers native gRPC with its
  `grpc-status` trailer and Connect over HTTP/2, through connect-node's adapter unchanged. Deno 2.5's
  `node:http2` loses `:method`, `:authority` and the socket, so the service needs 2.9 (the Deno
  pronto's apps pin); ci runs this suite on 2.9.7. `Deno.serve` takes h2c too but has no response
  trailers, so it cannot answer gRPC.
- **One port for HTTP/1.1 and HTTP/2.** A plain `node:http2` server refuses HTTP/1.1, so the
  service listens with `node:net` and hands each connection to the HTTP/2 server when it opens with
  the HTTP/2 preface (`PRI`), else to `node:http`. Cloud Run with end-to-end HTTP/2 sends only h2c;
  locally a browser's or curl's HTTP/1.1 reaches the same port.
- **REST through the same method.** A route (`GET /api/v1/ping/{text}`) fills the request from its
  path segments, its query and its JSON body (`fromJson` of the method's input), calls the same
  handler, and answers `toJson` of its output. Connect's codes map to HTTP statuses; an error the
  handler did not mean is `internal` with its message kept back, as connect-es does.
- **A missing service, method or route fails at start**, not on the first call.

Not settled here: Cloud Run's end-to-end HTTP/2 in front of it (PRONTO-320, the API on the wire).

```sh
deno test --no-config --allow-read --allow-write --allow-env --allow-run --allow-net tests/unit.ts -- api   # Deno 2.9
```
