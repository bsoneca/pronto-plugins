package unit

// The node host's Dapr sidecar repair (node/host/dapr-heal.sh, PRONTO-2191): aprende's flagd pod was created while the Dapr injector
// was down (the 2026-11-27 disk outage), annotated dapr.io/enabled=true and running flagd alone, so Dapr's calls to it were refused
// and every OFREP evaluation answered 500. tests/unit/daprheal.js runs the real script on a stand-in kubectl: a pod that asks for
// a sidecar and has none rolls its owner, once the injector can add it.

_bare: {ns: *"aprende" | string, name: *"aprende-flagd-6898744c57-m6m77" | string, owner: *"ReplicaSet/aprende-flagd-6898744c57" | string, containers: *["flagd"] | [...string], phase?: string, deleting?: bool, ageSec?: int}
_rs: {"aprende/aprende-flagd-6898744c57": "Deployment/aprende-flagd"}

cases: "a pod that asks for a sidecar and runs none rolls its Deployment": {
	suite: "daprheal"
	steps: [
		{call: "daprheal.run", args: [{pods: [_bare], rs: _rs}], holds: {code: 0, rolled: ["aprende/Deployment/aprende-flagd"], marked: ["aprende.Deployment.aprende-flagd"]}, why: "the ReplicaSet's owner is the Deployment: that is what is rolled"},
	]
}

cases: "a pod that runs its daprd is left alone": {
	suite: "daprheal"
	steps: [
		{call: "daprheal.run", args: [{pods: [(_bare & {containers: ["flagd", "daprd"]})], rs: _rs}], holds: {code: 0, rolled: [], out: "dapr-heal: every pod that asks for a Dapr sidecar runs one\n"}},
	]
}

cases: "no pod asks for a sidecar: nothing is read past the pods": {
	suite: "daprheal"
	steps: [
		{call: "daprheal.run", args: [{}], holds: {code: 0, rolled: []}},
	]
}

cases: "pods of one Deployment are rolled once, and each workload of its own": {
	suite: "daprheal"
	steps: [
		{call: "daprheal.run", args: [{pods: [_bare, (_bare & {name: "aprende-flagd-6898744c57-zzzzz"}), (_bare & {ns: "bonk", name: "bonk-crud-0", owner: "StatefulSet/bonk-crud", containers: ["crud"]})], rs: _rs}], holds: {code: 0, rolled: ["aprende/Deployment/aprende-flagd", "bonk/StatefulSet/bonk-crud"]}},
	]
}

cases: "a pod that is being deleted, finished or younger than the grace is not judged": {
	suite: "daprheal"
	steps: [
		{call: "daprheal.run", args: [{pods: [(_bare & {deleting: true}), (_bare & {name: "done", phase: "Succeeded"}), (_bare & {name: "new", ageSec: 30})], rs: _rs}], holds: {code: 0, rolled: []}},
	]
}

cases: "the injector without a ready replica rolls nothing and fails the run, naming the pod": {
	suite: "daprheal"
	steps: [
		{call: "daprheal.run", args: [{pods: [_bare], rs: _rs, injector: ""}], holds: {code: 1, rolled: [], marked: []}},
		{pick: ["err"], matches: "no ready replica.*\n  aprende\\|aprende-flagd-6898744c57-m6m77"},
	]
}

cases: "a workload rolled inside the cooldown is waited for, not rolled again, and the run is clean": {
	suite: "daprheal"
	steps: [
		{call: "daprheal.run", args: [{pods: [_bare], rs: _rs, marks: {"aprende.Deployment.aprende-flagd": 5}}], holds: {code: 0, rolled: []}},
	]
}

cases: "a workload rolled longer ago than the cooldown is rolled again": {
	suite: "daprheal"
	steps: [
		{call: "daprheal.run", args: [{pods: [_bare], rs: _rs, marks: {"aprende.Deployment.aprende-flagd": 45}}], holds: {code: 0, rolled: ["aprende/Deployment/aprende-flagd"]}},
	]
}

cases: "a Job's pod, a pod of its own and a ReplicaSet with no Deployment are not rolled, and the run fails": {
	suite: "daprheal"
	steps: [
		{call: "daprheal.run", args: [{pods: [(_bare & {owner: "Job/migrate"}), (_bare & {name: "solo", owner: ""}), (_bare & {name: "orphan", owner: "ReplicaSet/gone"})], rs: {"aprende/gone": ""}}], holds: {code: 1, rolled: []}},
	]
}

cases: "a roll that fails fails the run, leaves no mark, and the other workloads are still rolled": {
	suite: "daprheal"
	steps: [
		{call: "daprheal.run", args: [{pods: [_bare, (_bare & {ns: "bonk", name: "bonk-crud-0", owner: "StatefulSet/bonk-crud", containers: ["crud"]})], rs: _rs, failRoll: ["aprende/Deployment/aprende-flagd"]}], holds: {code: 1, rolled: ["bonk/StatefulSet/bonk-crud"], marked: ["bonk.StatefulSet.bonk-crud"]}},
	]
}

cases: "--dry-run says what it would roll and rolls and marks nothing": {
	suite: "daprheal"
	steps: [
		{call: "daprheal.run", args: [{pods: [_bare], rs: _rs, args: ["--dry-run"]}], holds: {code: 0, rolled: [], marked: [], out: "dapr-heal: would roll aprende/Deployment/aprende-flagd\n"}},
	]
}

cases: "an argument it does not know is refused": {
	suite: "daprheal"
	steps: [
		{call: "daprheal.run", args: [{args: ["--now"]}], holds: {code: 2}},
	]
}
