// The journeys reporter's error handling, run as a page runs it: telemetry.js is loaded with a page's
// globals stubbed, an error is thrown at its listeners and what leaves in the beacon is read back.
// `deno run --no-config --allow-read --allow-write --allow-env journeys/reporter_check.js` (journeys/reporter_test.nu).

const source = await Deno.readTextFile(new URL("./telemetry.js", import.meta.url));
const dir = await Deno.makeTempDir();
const file = `${dir}/telemetry.mjs`;
await Deno.writeTextFile(file, source);

const listeners = {};
const documentListeners = {};
const beacons = [];
let userAgent = "Mozilla/5.0";
Object.defineProperty(globalThis, "navigator", {
	configurable: true,
	value: { get userAgent() { return userAgent; }, sendBeacon: (_url, body) => { beacons.push(...JSON.parse(body)); return true; } },
});
globalThis.sessionStorage = { getItem: () => null, setItem() {}, removeItem() {} };
globalThis.addEventListener = (type, fn) => { listeners[type] = fn; };
globalThis.document = { visibilityState: "hidden", addEventListener: (type, fn) => { documentListeners[type] = fn; } };
// Each case is a page of its own: the reporter reports a few errors a page, so it is loaded afresh.
let pages = 0;
const load = async () => {
	delete globalThis.__prontoJourneys;
	await import(`${file}?page=${pages++}`);
};

let failed = 0;
const check = (what, ok) => {
	console.log(`${ok ? "ok" : "FAIL"}  ${what}`);
	if (!ok) failed++;
};

// An error thrown at the page's listener, as the browser would raise it, and the one error event it sends.
const thrown = async (error, { detail }) => {
	await load();
	globalThis.__prontoErrorDetail = detail;
	beacons.length = 0;
	listeners.error({ error, message: error.message });
	documentListeners.visibilitychange();
	return beacons.find((e) => e.type === "error");
};
const withStack = (message, frames, name = "Error") => {
	const error = new Error(message);
	error.name = name;
	error.stack = `${name}: ${message}\n${frames.map((f) => `    at ${f}`).join("\n")}`;
	return error;
};

// Off: the name alone, and nothing else, whatever the page threw.
const off = await thrown(withStack("secret ana@example.com", ["f (https://x.example/a.js:3:4)"]), { detail: false });
check("off, an error is its type, kind and name alone", JSON.stringify(Object.keys(off).sort()) === JSON.stringify(["kind", "name", "session", "t", "type"]));

// On: the saved-game message is dropped whole.
const game = await thrown(withStack("Illegal move in saved game: e2e4 in rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1", ["f (/a.js:3:4)"]), { detail: true });
check("a message holding a position or a move is dropped", game.message === "");
check("on, the event carries a browser tag from the fixed list", ["instagram", "facebook", "wv", "other"].includes(game.browser));

// The exception header never rides the stack, even ending in a location.
const header = await thrown(withStack("contact user@example.com:12:34", ["f (https://x.example/a.js:3:4)"]), { detail: true });
check("a header that ends in a location is no frame", !JSON.stringify(header).includes("user@") && header.frame === "f (/a.js:3:4)");

// A query or fragment with ")" or ":" in it ends nothing.
const query = await thrown(withStack("x", ["f (https://x.example/app.js?state=x)private:3:4)", "g (https://x.example/b.js#t=a:b:5:6)"]), { detail: true });
check("a query or fragment is left out whole", query.stack === "f (/app.js:3:4)\ng (/b.js:5:6)");

// Paths: a long legitimate one is kept, an address or a token in a segment is not, encoded or not.
const paths = await thrown(
	withStack("x", [
		"a (https://x.example/shell/hatches/journeys/telemetry.js:1:2)",
		"b (https://x.example/users/ana@example.com/app.js:3:4)",
		"c (https://x.example/users/ana%40gmail.com/app.js:5:6)",
		"d (https://x.example/u/eyJhbGciOiJIUzI1NiJ9.e30.abc/b.js:7:8)",
		"e (https://x.example/assets/keyJson.js:9:10)",
	]),
	{ detail: true },
);
const lines = paths.stack.split("\n");
check("a long legitimate path is kept", lines[0] === "a (/shell/hatches/journeys/telemetry.js:1:2)");
check("an address in a path segment is scrubbed", lines[1] === "b (/users/<email>/app.js:3:4)");
check("an encoded address in a path segment is scrubbed", lines[2] === "c (/users/<email>/app.js:5:6)");
check("a token in a path segment is scrubbed", lines[3] === "d (/u/<token>/b.js:7:8)");
check("a file named keyJson.js is kept", lines[4] === "e (/assets/keyJson.js:9:10)");

// A malformed escape hides an encoded address in the same segment: the segment goes as a marker.
const malformed = await thrown(withStack("x", ["h (https://x.example/users/ana%40gmail.com%E0%A4%A/app.js:1:2)", "i (https://x.example/ok/app.js:3:4)"]), { detail: true });
check("a segment that fails to decode is a fixed marker, its address nowhere", malformed.stack === "h (/users/<undecodable>/app.js:1:2)\ni (/ok/app.js:3:4)" && !JSON.stringify(malformed).includes("ana") && !JSON.stringify(malformed).includes("gmail"));

// Decoded until it stops changing; a decoded newline cannot split the stack; a name keeps its ending.
const tricky = await thrown(withStack("x", ["j (https://x.example/a/ana%2540gmail.com/app.js:1:2)", "k (https://x.example/b/ana%40gmail.com%0Aat%20x/app.js:3:4)", "l (https://x.example/c/x%E0.js:5:6)", "m (https://x.example/d/ana@example.com.js:7:8)"]), { detail: true });
const trickyLines = tricky.stack.split("\n");
check("a double-encoded address is scrubbed", trickyLines[0] === "j (/a/<email>/app.js:1:2)");
check("a decoded newline cannot split the stack", trickyLines.length === 4 && trickyLines[1].startsWith("k (/b/") && !trickyLines[1].includes("ana") && trickyLines[2] === "l (/c/<undecodable>.js:5:6)");
check("a scrubbed file name keeps its ending", trickyLines[3] === "m (/d/<email>.js:7:8)");

// A lone surrogate in a scrubbed segment makes its re-escape throw: that must not lose the beacon, the segment is the marker.
const lone = await thrown(withStack("x", ["n (https://x.example/e/ana@example.com\uD800/app.js:1:2)", "o (https://x.example/ok/app.js:3:4)"]), { detail: true });
check("a lone surrogate in a scrubbed segment does not lose the beacon or the address", lone !== undefined && !lone.stack.includes("ana") && lone.stack.split("\n").length === 2 && lone.stack.endsWith("o (/ok/app.js:3:4)"));

// A valid emoji and an address in one segment: the name is escaped whole, not discarded.
const emoji = await thrown(withStack("x", ["p (https://x.example/f/\u{1F600}ana@example.com/app.js:1:2)"]), { detail: true });
check("a valid emoji beside an address is kept, escaped", emoji.stack === "p (/f/%F0%9F%98%80<email>/app.js:1:2)");

// A relative query or fragment leaks whatever precedes it: any ? # & that starts a key=value goes.
for (const [input, kept] of [["page.html?token=s1", "page.html"], ["?token=s2", ""], ["#access_token=s3", ""], ["/a+b?k=s4", "/a+b"], ["/caf\u00e9?k=s5", "/caf\u00e9"], ["x=1&token=s6", "x=1"]]) {
	const e = await thrown(withStack(`failed ${input} end`, ["f (/a.js:1:2)"]), { detail: true });
	check(`a relative query is dropped: ${input}`, e.message === `failed ${kept} end` && !/s[1-6]\b/.test(e.message));
}

// A phone with a parenthesized area code survives a digit-run rule: each format is gone, short numbers stay.
for (const phone of ["(212) 555-0123", "+1 (212) 555-0123", "212.555.0123", "212-555-0123", "(11) 91234-5678", "+55 (11) 91234 5678"]) {
	const e = await thrown(withStack(`call ${phone} now`, ["f (/a.js:1:2)"]), { detail: true });
	check(`a phone is gone: ${phone}`, e.message === "call <number> now");
}
const short = await thrown(withStack("level 12 at 14:32:05 move 7 of 40 on 2026-11-27", ["f (/a.js:1:2)"]), { detail: true });
check("levels, times and moves are kept", short.message.startsWith("level 12 at 14:32:05 move 7 of 40 on"));

// URL schemes are case-insensitive; a relative url's query is private too; no lookbehind (older Safari fails to parse one).
const urls = await thrown(withStack("see HTTPS://example.org/?invite=blue-fox and Http://x.example/a?k=v and /path?token=secret#frag", ["f (/a.js:1:2)"]), { detail: true });
check("a mixed-case scheme and a relative url lose their query", !/blue-fox|token=|secret|k=v/.test(JSON.stringify(urls)) && urls.message.includes("<url>"));
check("the reporter source has no lookbehind regex", !/\(\?<[!=]/.test(source));
const jwt = await thrown(withStack("bad eyJhbGciOiJIUzI1NiJ9.e30.abc in keyJson.js", ["f (/a.js:1:2)"]), { detail: true });
check("a token is cut and keyJson.js is kept without a lookbehind", jwt.message === "bad <token> in keyJson.js");

// The message: redacted in the page.
const message = await thrown(withStack("failed for ana@example.com at https://x.example/p?q=1", ["f (/a.js:1:2)"]), { detail: true });
check("a message loses its address and url", message.message === "failed for <email> at <url>");

// The tag.
userAgent = "Mozilla/5.0 (iPhone) Instagram 457.0.0.34.70 (iPhone14,5)";
check("an Instagram user agent is tagged instagram and the agent itself is not sent", (await thrown(withStack("x", ["f (/a.js:1:2)"]), { detail: true })).browser === "instagram" && !JSON.stringify(beacons).includes("iPhone"));

await Deno.remove(dir, { recursive: true });
if (failed) Deno.exit(1);
