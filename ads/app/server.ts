// The ad document's service (pronto-ads): answers the one document Google's ads play in, at an origin of
// its own, with the policy that holds it, both as generate wrote them to ads/break.json from
// ads_plugin.cue. Nothing else is answered: every other path is a 404 that loads nothing.
// Written by pronto-ads; regenerated, do not edit.

/** What ads/break.json holds: the document and the policy of its response. */
export type Break = { document: string; csp: string };

const NOTHING = "default-src 'none'";

/** The service, on the document it serves: a pure answer to a request. */
export function handle(req: Request, page: Break): Response {
  const path = new URL(req.url).pathname;
  if (path === "/health") return new Response("ok", { headers: { "Content-Type": "text/plain; charset=utf-8", "Content-Security-Policy": NOTHING } });
  if (path !== "/break") return new Response("not found", { status: 404, headers: { "Content-Type": "text/plain; charset=utf-8", "Content-Security-Policy": NOTHING } });
  if (req.method !== "GET" && req.method !== "HEAD") return new Response("method not allowed", { status: 405, headers: { Allow: "GET, HEAD", "Content-Security-Policy": NOTHING } });
  return new Response(req.method === "HEAD" ? null : page.document, {
    headers: {
      "Content-Type": "text/html; charset=utf-8",
      "Content-Security-Policy": page.csp,
      "X-Content-Type-Options": "nosniff",
      "Cache-Control": "no-cache",
    },
  });
}

if (import.meta.main) {
  const page: Break = JSON.parse(await Deno.readTextFile(new URL("./break.json", import.meta.url)));
  const port = Number(Deno.env.get("ADS_PORT") ?? 8700);
  Deno.serve({ port }, (req) => handle(req, page));
}
