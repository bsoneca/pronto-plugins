// integrate@android's pure rules (android/template/terminal/scenarios.ts): how a scenario's text is
// filled, a step is read, a text is typed on a phone and an expectation is held to the DOM's elements.
package unit

_el: {text: *"" | string, attrs: {...}, hidden: false, id: "e1"}

cases: {
	"a kept value and a name fill the text, and a name nobody kept fails": {suite: "android", steps: [
		{call: "androidScenarios.substitute", args: ["Ana {who} says {what}", {who: "Ana 7", what: "hi"}], expect: "Ana Ana 7 says hi"},
		{call: "androidScenarios.substitute", args: ["{nope}", {}], throws: "nothing kept as \\{nope\\}"},
	]}
	"each {uuid} is fresh": {suite: "android", steps: [
		{call: "androidScenarios.substitute", args: ["{uuid}|{uuid}", {}], matches: "^[0-9a-f-]{36}\\|[0-9a-f-]{36}$"},
	]}
	"a step is its one action or expectation, 15 seconds by default": {suite: "android", steps: [
		{call: "androidScenarios.normalize", args: [{by: "ana", click: ".sign", why: "go"}], holds: {by: "ana", kind: "click", arg: ".sign", timeout: 15, why: "go"}},
		{call: "androidScenarios.normalize", args: [{text: {of: ".e", has: "x"}, timeout: 30}], holds: {kind: "text", timeout: 30, arg: {of: ".e", has: "x"}}},
	]}
	"a step kind the phone does not know fails, naming it": {suite: "android", steps: [
		{call: "androidScenarios.normalize", args: [{drag: {from: "a", to: "b"}}], throws: "unknown step kind \"drag\""},
		{call: "androidScenarios.normalize", args: [{see: "a", hidden: "b"}], throws: "one action or expectation"},
	]}
	"an actor is the step's by, the only one there is, or the one acting": {suite: "android", steps: [
		{call: "androidScenarios.actorOf", args: [{by: "bia", open: "/"}, {ana: {name: "Ana"}, bia: {name: "Bia"}}, "ana"], expect: "bia"},
		{call: "androidScenarios.actorOf", args: [{open: "/"}, {ana: {name: "Ana"}}, null], expect: "ana"},
		{call: "androidScenarios.actorOf", args: [{see: "a"}, {ana: {name: "Ana"}, bia: {name: "Bia"}}, "bia"], expect: "bia"},
		{call: "androidScenarios.actorOf", args: [{open: "/"}, {}, null], expect: "me"},
	]}
	"input text is quoted for the device's shell, spaces as %s": {suite: "android", steps: [
		{call: "androidScenarios.inputText", args: ["Signed from the Unity host."], expect: "'Signed%sfrom%sthe%sUnity%shost.'"},
		{call: "androidScenarios.inputText", args: ["it's $HOME; `x` & \"y\""], expect: "'it'\\''s%s$HOME;%s`x`%s&%s\"y\"'"},
		{call: "androidScenarios.inputText", args: ["caf\u00e9"], throws: "only printable ASCII"},
	]}
	"keys press as Android's key events, a character is typed": {suite: "android", steps: [
		{call: "androidScenarios.keyOf", args: ["Enter"], expect: {keyevent: "KEYCODE_ENTER"}},
		{call: "androidScenarios.keyOf", args: ["a"], expect: {text: "a"}},
		{call: "androidScenarios.keyOf", args: ["F13"], throws: "no key"},
	]}
	"a box off the screen scrolls the way it lies, and the tap is its middle": {suite: "android", steps: [
		{call: "androidScenarios.scrollFor", args: [{x: 0, y: 2400, w: 100, h: 100}, {w: 1080, h: 2400}], expect: "up"},
		{call: "androidScenarios.scrollFor", args: [{x: 0, y: -300, w: 100, h: 100}, {w: 1080, h: 2400}], expect: "down"},
		{call: "androidScenarios.scrollFor", args: [{x: 0, y: 500, w: 100, h: 100}, {w: 1080, h: 2400}], expect: null},
		{call: "androidScenarios.centre", args: [{x: 100, y: 200, w: 51, h: 40}], expect: {x: 126, y: 220}},
	]}
	"see needs an element not hidden and drawn, hidden and attached do not": {suite: "android", steps: [
		{call: "androidScenarios.holds", args: ["see", ".a", [_el & {shown: true}]], expect: null},
		{call: "androidScenarios.holds", args: ["see", ".a", [_el & {shown: false}]], matches: "none shown"},
		{call: "androidScenarios.holds", args: ["hidden", ".a", []], expect: null},
		{call: "androidScenarios.holds", args: ["hidden", ".a", [_el & {shown: true}]], expect: "shown"},
		{call: "androidScenarios.holds", args: ["attached", ".a", [_el & {shown: false}]], expect: null},
		{call: "androidScenarios.holds", args: ["attached", ".a", []], matches: "none"},
	]}
	"count, text, value and attr are held to the first element as the web holds them": {suite: "android", steps: [
		{call: "androidScenarios.holds", args: ["count", {of: ".a", is: 2}, [_el, _el]], expect: null},
		{call: "androidScenarios.holds", args: ["count", {of: ".a", atLeast: 3}, [_el, _el]], matches: "at least 3"},
		{call: "androidScenarios.holds", args: ["text", {of: ".a", has: "Ana 7"}, [_el & {text: "wrote Ana 7 here"}]], expect: null},
		{call: "androidScenarios.holds", args: ["text", {of: ".a", is: "x"}, [_el & {text: "y"}]], matches: "want \"x\""},
		{call: "androidScenarios.holds", args: ["text", {of: ".a", msg: "hint"}, [_el & {text: "Leave a name"}], {hint: "Leave a name"}], expect: null},
		{call: "androidScenarios.holds", args: ["text", {of: ".a", msg: "nope"}, [_el], {}], throws: "no message nope"},
		{call: "androidScenarios.holds", args: ["value", {of: "input", is: ""}, [_el]], expect: null},
		{call: "androidScenarios.holds", args: ["value", {of: "input", is: "a"}, [_el & {value: "b"}]], matches: "value is \"b\""},
		{call: "androidScenarios.holds", args: ["attr", {of: ".s", name: "data-state", matches: "^(empty|populated)$"}, [_el & {attrs: {"data-state": "empty"}}]], expect: null},
		{call: "androidScenarios.holds", args: ["attr", {of: ".s", name: "data-state", is: "validation-error"}, [_el & {attrs: {"data-state": "empty"}}]], matches: "want \"validation-error\""},
		{call: "androidScenarios.holds", args: ["attr", {of: ".s", name: "n", below: 5}, [_el & {attrs: {n: "7"}}]], matches: "below 5"},
	]}
	"a trip in the browser ends back at the app's own origin, never at the door's sign-in routes": {suite: "android", steps: [
		{call: "androidScenarios.backTo", args: ["https://localhost:33600/beginner?pro=1#x", "https://localhost:33600"], expect: true},
		{call: "androidScenarios.backTo", args: ["https://localhost:33600/", "https://localhost:33600/"], expect: true},
		{call: "androidScenarios.backTo", args: ["https://localhost:33600/auth/oidc/google/callback", "https://localhost:33600"], expect: false},
		{call: "androidScenarios.backTo", args: ["http://localhost:28463/pay/cs_1", "https://localhost:33600"], expect: false},
		{call: "androidScenarios.backTo", args: ["https://localhost:33601/", "https://localhost:33600"], expect: false},
		{call: "androidScenarios.backTo", args: ["https://checkout.stripe.com/c/pay/cs_1", "https://prontoweeper.example"], expect: false},
	]}
	"a form's submission is HTML's: a GET in the query, a POST in an urlencoded body, at its action or the page": {suite: "android", steps: [
		{call: "androidScenarios.submission", args: ["http://localhost:28463/pay/cs_1", "/pay/cs_1/confirm", "post", [["paid", "yes"], ["note", "a b&c"]]], expect: {url: "http://localhost:28463/pay/cs_1/confirm", method: "POST", body: "paid=yes&note=a+b%26c"}},
		{call: "androidScenarios.submission", args: ["http://localhost:28463/pay/cs_1?old=1#top", null, null, [["q", "x"]]], expect: {url: "http://localhost:28463/pay/cs_1?q=x", method: "GET"}},
		{call: "androidScenarios.submission", args: ["http://localhost:28463/a/b", "c", "POST", []], expect: {url: "http://localhost:28463/a/c", method: "POST", body: ""}},
	]}
}
