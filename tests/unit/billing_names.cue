// A plan's name, judged by one rule (billing/rules.cue: nameMax code points, nameText): the CUE spec
// and the broker's parsePublished are tried on the same names, and any disagreement fails.
package unit

cases: {
	"a name of 80 supplementary characters is accepted, 81 refused, by CUE and the broker alike": {suite: "billing", steps: [
		{call: "probe.repeat", args: ["𝐀", 80]}, {keep: "ok"},
		{call: "billingNames.accepted", args: ["$ok"], expect: true},
		{call: "probe.repeat", args: ["𝐀", 81]}, {keep: "over"},
		{call: "billingNames.accepted", args: ["$over"], expect: false},
	]}
	"a name of blanks only is refused by CUE and the broker alike": {suite: "billing", steps: [
		{call: "billingNames.accepted", args: ["   "], expect: false},
		{call: "billingNames.accepted", args: [" \t\n\r\f "], expect: false},
		{call: "billingNames.accepted", args: [""], expect: false},
	]}
	"a no-break or other Unicode space is text, so a name of it is accepted by both": {suite: "billing", steps: [
		{call: "billingNames.accepted", args: [" "], expect: true},
		{call: "billingNames.accepted", args: ["　 "], expect: true},
	]}
	"the broker trims only the blank the rule names": {suite: "billing", steps: [
		{call: "billingNames.kept", args: ["  Plus \n"], expect: "Plus"},
		{call: "billingNames.kept", args: [" Plus "], expect: " Plus "},
	]}
}
