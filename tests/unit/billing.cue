// What the billing service logs of a failed answer (billing/service.ts brief): one line, the status
// beside at most 120 characters of the body, never a page a line at a time.
package unit

_page: "<html><head>\n<meta http-equiv=\"content-type\" content=\"text/html;charset=utf-8\">\n<title>500 Server Error</title>\n<style>body{margin:0}</style></head>\n<body><h1>Error</h1>\n<h2>The server encountered a temporary error.</h2></body></html>"

cases: {
	"an HTML error page is its title, on one line": {suite: "billing", steps: [
		{call: "billing.brief", args: [_page], expect: "500 Server Error"},
	]}
	"a body without a title has its tags stripped and its whitespace collapsed": {suite: "billing", steps: [
		{call: "billing.brief", args: ["<p>Bad\n\n  gateway</p>\n<br/>try again"], expect: "Bad gateway try again"},
		{call: "billing.brief", args: [""], expect: ""},
	]}
	"a long body is cut to 120 characters, marked": {suite: "billing", steps: [
		{call: "probe.repeat", args: ["ab ", 100]}, {keep: "long"},
		{call: "billing.brief", args: ["$long"]}, {keep: "cut"},
		{call: "probe.length", args: ["$cut"], expect: 120},
		{call: "probe.includes", args: ["$cut", "..."], expect: true},
	]}
	"a neighbour not up yet is waited for in the startup window, any other failure fails": {suite: "billing", steps: [
		{call: "billing.grantVerdict", args: [false, 2000, true], expect: "wait"},
		{call: "billing.grantVerdict", args: [false, 59999, true], expect: "wait"},
		{call: "billing.grantVerdict", args: [false, 60000, true], expect: "fail"},
		{call: "billing.grantVerdict", args: [false, 70000, true], expect: "fail"},
		{call: "billing.grantVerdict", args: [true, 2000, true], expect: "fail"},
		{call: "billing.grantVerdict", args: [false, 2000, false], expect: "fail"},
	]}
}
