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
await import(file);

let failed = 0;
const check = (what, ok) => {
	console.log(`${ok ? "ok" : "FAIL"}  ${what}`);
	if (!ok) failed++;
};

// An error thrown at the page's listener, as the browser would raise it, and the one error event it sends.
const thrown = (error, { detail }) => {
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
const off = thrown(withStack("secret ana@example.com", ["f (https://x.example/a.js:3:4)"]), { detail: false });
check("off, an error is its type, kind and name alone", JSON.stringify(Object.keys(off).sort()) === JSON.stringify(["kind", "name", "session", "t", "type"]));

// On: the saved-game message is dropped whole.
const game = thrown(withStack("Illegal move in saved game: e2e4 in rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1", ["f (/a.js:3:4)"]), { detail: true });
check("a message holding a position or a move is dropped", game.message === "");
check("on, the event carries a browser tag from the fixed list", ["instagram", "facebook", "wv", "other"].includes(game.browser));

// The exception header never rides the stack, even ending in a location.
const header = thrown(withStack("contact user@example.com:12:34", ["f (https://x.example/a.js:3:4)"]), { detail: true });
check("a header that ends in a location is no frame", !JSON.stringify(header).includes("user@") && header.frame === "f (/a.js:3:4)");

// A query or fragment with ")" or ":" in it ends nothing.
const query = thrown(withStack("x", ["f (https://x.example/app.js?state=x)private:3:4)", "g (https://x.example/b.js#t=a:b:5:6)"]), { detail: true });
check("a query or fragment is left out whole", query.stack === "f (/app.js:3:4)\ng (/b.js:5:6)");

// Paths: a long legitimate one is kept, an address or a token in a segment is not, encoded or not.
const paths = thrown(
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

// The message: redacted in the page.
const message = thrown(withStack("failed for ana@example.com at https://x.example/p?q=1", ["f (/a.js:1:2)"]), { detail: true });
check("a message loses its address and url", message.message === "failed for <email> at <url>");

// The tag.
userAgent = "Mozilla/5.0 (iPhone) Instagram 457.0.0.34.70 (iPhone14,5)";
check("an Instagram user agent is tagged instagram and the agent itself is not sent", thrown(withStack("x", ["f (/a.js:1:2)"]), { detail: true }).browser === "instagram" && !JSON.stringify(beacons).includes("iPhone"));

await Deno.remove(dir, { recursive: true });
if (failed) Deno.exit(1);
