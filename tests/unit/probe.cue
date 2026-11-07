// pronto-probe's rules (probe/probe.js): a probe's state over consecutive runs, which flag writes
// are suspects of a failure, and the durations the schema names.
package unit

_ok: {status: "ok", failures: 0, firstFailureAt: null, alertedAt: null}
_fail: {ok: false}
_pass: {ok: true}

// A flag write as pronto-flags journals it.
_write: {
	at:      string
	flag:    *"drill_break_checkout" | string
	version: *"7" | string
	from:    *"6" | string
	stage:   *"all" | string
	out: {
		"at": at, event: "flags.write", app: "drill", target: "file:.flags-live", "version": version, "from": from, "stage": stage
		"flag": flag, who: "bruno", commit: "abc1234", cases: "passed", note: "", changes: [{"flag": "drill_break_checkout", from: false, to: true}]
	}
}

cases: {
	"a run that passes keeps the probe ok and says nothing": {suite: "probe", steps: [
		{call: "prober.step", args: [_ok, _pass, "2026-11-07T12:00:00Z", {after: 2}], holds: {state: _ok, events: []}},
	]}
	"one failure below the threshold is failing, with no alert": {suite: "probe", steps: [
		{call: "prober.step", args: [_ok, _fail, "2026-11-07T12:00:00Z", {after: 2}], holds: {state: {status: "failing", failures: 1, firstFailureAt: "2026-11-07T12:00:00Z"}, events: []}},
	]}
	"the failure that reaches the threshold alerts, naming the first failure": {suite: "probe", steps: [
		{call: "prober.step", args: [_ok, _fail, "2026-11-07T12:00:00Z", {after: 2}]},
		{get: "state"},
		{call: "prober.step", args: ["$", _fail, "2026-11-07T12:00:05Z", {after: 2}], holds: {state: {status: "alerting", failures: 2, firstFailureAt: "2026-11-07T12:00:00Z"}, events: [{event: "probe.alert", at: "2026-11-07T12:00:05Z", firstFailureAt: "2026-11-07T12:00:00Z", failures: 2}]}},
	]}
	"a third failure does not alert again": {suite: "probe", steps: [
		{call: "prober.step", args: [{status: "alerting", failures: 2, firstFailureAt: "2026-11-07T12:00:00Z", alertedAt: "2026-11-07T12:00:05Z"}, _fail, "2026-11-07T12:00:10Z", {after: 2}], holds: {state: {status: "alerting", failures: 3, firstFailureAt: "2026-11-07T12:00:00Z"}, events: []}},
	]}
	"a pass after the alert resolves it, with how long it was down": {suite: "probe", steps: [
		{call: "prober.step", args: [{status: "alerting", failures: 3, firstFailureAt: "2026-11-07T12:00:00Z", alertedAt: "2026-11-07T12:00:05Z"}, _pass, "2026-11-07T12:00:15Z", {after: 2}], holds: {state: _ok, events: [{event: "probe.resolved", at: "2026-11-07T12:00:15Z", firstFailureAt: "2026-11-07T12:00:00Z", failures: 3, downFor: 15000}]}},
	]}
	"a pass before the alert forgets the blip and resolves nothing": {suite: "probe", steps: [
		{call: "prober.step", args: [{status: "failing", failures: 1, firstFailureAt: "2026-11-07T12:00:00Z", alertedAt: null}, _pass, "2026-11-07T12:00:05Z", {after: 2}], holds: {state: _ok, events: []}},
	]}
	"after is the threshold: three consecutive failures when the probe says three": {suite: "probe", steps: [
		{call: "prober.step", args: [{status: "failing", failures: 2, firstFailureAt: "2026-11-07T12:00:00Z", alertedAt: null}, _fail, "2026-11-07T12:00:10Z", {after: 3}], holds: {state: {status: "alerting", failures: 3}, events: [{event: "probe.alert", failures: 3}]}},
	]}
	"a flag write just before the first failure is a suspect, with the command that undoes it": {suite: "probe", steps: [
		{call: "prober.suspects", args: [[(_write & {at: "2026-11-07T11:59:00Z"}).out], "2026-11-07T12:00:00Z", 900000], holds: [{at: "2026-11-07T11:59:00Z", flag: "drill_break_checkout", version: "7", from: "6", who: "bruno", commit: "abc1234", rollback: "pronto-flags rollback <app-dir> 6"}]},
	]}
	"a write older than the window is not a suspect": {suite: "probe", steps: [
		{call: "prober.suspects", args: [[(_write & {at: "2026-11-07T11:30:00Z"}).out], "2026-11-07T12:00:00Z", 900000], expect: []},
	]}
	"a write after the first failure is not a suspect": {suite: "probe", steps: [
		{call: "prober.suspects", args: [[(_write & {at: "2026-11-07T12:00:01Z"}).out], "2026-11-07T12:00:00Z", 900000], expect: []},
	]}
	"a write that changed no flag is not a suspect": {suite: "probe", steps: [
		{call: "prober.suspects", args: [[(_write & {at: "2026-11-07T11:59:00Z", flag: ""}).out], "2026-11-07T12:00:00Z", 900000], expect: []},
	]}
	"suspects come newest first, and the command of each undoes its own write": {suite: "probe", steps: [
		{call: "prober.suspects", args: [[(_write & {at: "2026-11-07T11:50:00Z", flag: "a", version: "5", from: "4"}).out, (_write & {at: "2026-11-07T11:58:00Z", flag: "b+c", version: "6", from: "5"}).out], "2026-11-07T12:00:00Z", 900000]},
		{pick: ["0.flag", "1.flag", "0.rollback", "1.rollback"], expect: ["b+c", "a", "pronto-flags rollback <app-dir> 5", "pronto-flags rollback <app-dir> 4"]},
	]}
	"a flip's final write is undone past its canary, to the version the flip started from": {suite: "probe", steps: [
		{call: "prober.suspects", args: [[(_write & {at: "2026-11-07T11:58:00Z", flag: "a", version: "6", from: "5", stage: "testers"}).out, (_write & {at: "2026-11-07T11:59:00Z", flag: "a", version: "7", from: "6", stage: "all"}).out], "2026-11-07T12:00:00Z", 900000]},
		{pick: ["0.version", "0.from", "0.rollback", "1.rollback"], expect: ["7", "5", "pronto-flags rollback <app-dir> 5", "pronto-flags rollback <app-dir> 5"]},
	]}
	"the first write of a store has nothing to roll back to": {suite: "probe", steps: [
		{call: "prober.suspects", args: [[(_write & {at: "2026-11-07T11:59:00Z", version: "1", from: "0"}).out], "2026-11-07T12:00:00Z", 900000]},
		{pick: ["0.rollback"], expect: [""]},
	]}
	"a journal line is read as text, and a line that is not JSON is skipped": {suite: "probe", steps: [
		{call: "prober.suspects", args: [["not json", "{\"at\":\"2026-11-07T11:59:00Z\",\"event\":\"flags.write\",\"flag\":\"x\",\"version\":\"2\",\"from\":\"1\"}", "{\"at\":\"2026-11-07T11:59:30Z\",\"event\":\"other\",\"flag\":\"y\"}"], "2026-11-07T12:00:00Z", 900000]},
		{pick: ["length", "0.flag"], expect: [1, "x"]},
	]}
	"durations are text of a number and a unit": {suite: "probe", steps: [
		{call: "prober.parseDuration", args: ["250ms"], expect: 250},
		{call: "prober.parseDuration", args: ["15s"], expect: 15000},
		{call: "prober.parseDuration", args: ["15m"], expect: 900000},
		{call: "prober.parseDuration", args: ["2h"], expect: 7200000},
		{call: "prober.parseDuration", args: ["soon"], throws: "like 250ms"},
	]}
}
