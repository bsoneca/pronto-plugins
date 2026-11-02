// A stand-in for Umami on a host launch, written by pronto-analytics: the tracker's two
// addresses, so the page's loader and its reports can be exercised with no database and no
// container. GET <script> answers a tracker that posts one pageview to <collect> as Umami's does;
// POST <collect> counts it; GET /stats says what it has counted (for the checks).
// It keeps nothing of what it is sent but a count.
const port = Number(Deno.env.get("UMAMI_PORT") ?? "3000");
const script = Deno.env.get("UMAMI_SCRIPT") ?? "/a/s.js";
const collect = Deno.env.get("UMAMI_COLLECT") ?? "/a/e";
let pageviews = 0;
let sites = new Set<string>();

// As Umami's tracker finds its collector: the host it is told (data-host-url), else the address of
// the script's own directory, followed by the endpoint the server was configured with.
const tracker = `(()=>{const s=document.currentScript;if(!s)return;const w=s.getAttribute("data-website-id");` +
	`const h=s.getAttribute("data-host-url")||s.src.split("/").slice(0,-1).join("/");` +
	`fetch(h+${JSON.stringify(collect)},{method:"POST",headers:{"content-type":"application/json"},` +
	`body:JSON.stringify({type:"event",payload:{website:w,url:location.pathname,hostname:location.hostname,language:navigator.language,screen:screen.width+"x"+screen.height}})})})();`;

Deno.serve({ hostname: "127.0.0.1", port }, async (req) => {
	const url = new URL(req.url);
	if (req.method === "GET" && url.pathname === script) {
		return new Response(tracker, { headers: { "content-type": "text/javascript", "cache-control": "no-store" } });
	}
	if (req.method === "POST" && url.pathname === collect) {
		const body = await req.json().catch(() => null);
		if (body?.type !== "event" || typeof body?.payload?.website !== "string") return new Response("bad event", { status: 400 });
		pageviews++;
		sites.add(body.payload.website);
		return Response.json({ ok: true });
	}
	if (url.pathname === "/stats") return Response.json({ pageviews, sites: [...sites] });
	return new Response("not found", { status: 404 });
});
