package unit

// The node host's Dapr sidecar repair (node/host/dapr-heal.sh, PRONTO-2191): aprende's flagd pod was created while the Dapr injector
// was down (the 2026-11-27 disk outage), annotated dapr.io/enabled=true and running flagd alone, so Dapr's calls to it were refused
// and every OFREP evaluation answered 500. tests/unit/daprheal.js runs the real script on a stand-in kubectl: a pod that asks for
// a sidecar and has none rolls its owner, once the injector can add it.

_bare: {ns: *"aprende" | string, name: *"aprende-flagd-6898744c57-m6m77" | string, owner: *"ReplicaSet/aprende-flagd-6898744c57" | string, containers: *["flagd"] | [...string], phase?: string, deleting?: bool, ageSec?: int, init?: [...string]}
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

cases: "a workload rolled longer ago than the cooldown with a pod still bare, of any age, is an error and is not rolled again": {
	suite: "daprheal"
	steps: [
		{call: "daprheal.run", args: [{pods: [_bare], rs: _rs, marks: {"aprende.Deployment.aprende-flagd": 45}}], holds: {code: 1, rolled: [], marked: ["aprende.Deployment.aprende-flagd"]}, why: "an old bare pod: the rollout did not replace it (OnDelete, paused, a stuck ordered StatefulSet, a Pending pod): another roll would not either, and it must not stay green"},
		{pick: ["err"], matches: "past the cooldown of 30 minutes, a pod it covered or made is still without its sidecar: not rolled again"},
		{call: "daprheal.run", args: [{pods: [(_bare & {ageSec: 600})], rs: _rs, marks: {"aprende.Deployment.aprende-flagd": 45}}], holds: {code: 1, rolled: []}, why: "a pod created after the roll: the injector injects nothing for it"},
	]
}

cases: "the mark of a workload with no bare pod is removed, so a later outage is repaired, not failed": {
	suite: "daprheal"
	steps: [
		{call: "daprheal.run", args: [{pods: [(_bare & {containers: ["flagd", "daprd"]})], rs: _rs, marks: {"aprende.Deployment.aprende-flagd": 45}}], holds: {code: 0, rolled: [], marked: []}, why: "all of its pods run their sidecar: the incident is over"},
		{call: "daprheal.run", args: [{pods: [(_bare & {ns: "bonk", name: "bonk-crud-0", owner: "StatefulSet/bonk-crud", containers: ["crud"]})], marks: {"aprende.Deployment.aprende-flagd": 45, "bonk.StatefulSet.bonk-crud": 5}}], holds: {code: 0, rolled: [], marked: ["bonk.StatefulSet.bonk-crud"]}, why: "a bare pod elsewhere: only its own workload's mark stays"},
		{call: "daprheal.run", args: [{pods: [(_bare & {ageSec: 30})], rs: _rs, marks: {"aprende.Deployment.aprende-flagd": 45}}], holds: {code: 0, rolled: [], marked: ["aprende.Deployment.aprende-flagd"]}, why: "a young bare pod is not judged, but its workload is not healthy: its mark stays, or the roll would repeat every grace"},
		{call: "daprheal.run", args: [{pods: [_bare], rs: _rs, marks: {"aprende.Deployment.aprende-flagd": 45}, args: ["--dry-run"]}], holds: {marked: ["aprende.Deployment.aprende-flagd"]}, why: "a dry run removes nothing"},
	]
}

cases: "only the operator's namespaces are swept: a tenant's pod is never rolled nor makes the run fail": {
	suite: "daprheal"
	steps: [
		{call: "daprheal.run", args: [{pods: [(_bare & {ns: "studio-ana-game-1a2b3c", owner: "Job/x"}), (_bare & {ns: "dapr-system"})], rs: _rs}], holds: {code: 0, rolled: [], out: "dapr-heal: every pod that asks for a Dapr sidecar runs one\n"}},
		{call: "daprheal.run", args: [{pods: [(_bare & {ns: "studio-ana-game-1a2b3c"})], rs: {"studio-ana-game-1a2b3c/aprende-flagd-6898744c57": "Deployment/x"}, namespaces: ["studio-ana-game-1a2b3c"]}], holds: {rolled: ["studio-ana-game-1a2b3c/Deployment/x"]}, why: "the script rolls what it is told to sweep: the schema is what refuses a tenant's namespace"},
	]
}

cases: "a daprd among the init containers (a native sidecar) is a sidecar": {
	suite: "daprheal"
	steps: [
		{call: "daprheal.run", args: [{pods: [(_bare & {init: ["daprd"]})], rs: _rs}], holds: {code: 0, rolled: []}},
	]
}

cases: "a Job's pod, a pod of its own and a ReplicaSet with no Deployment are not rolled, and the run fails": {
	suite: "daprheal"
	steps: [
		{call: "daprheal.run", args: [{pods: [(_bare & {owner: "Job/migrate"}), (_bare & {name: "solo", owner: ""}), (_bare & {name: "orphan", owner: "ReplicaSet/gone"})], rs: {"aprende/gone": ""}}], holds: {code: 1, rolled: []}},
	]
}

cases: "a roll the API refused fails the run, keeps its mark, and the other workloads are still rolled": {
	suite: "daprheal"
	steps: [
		{call: "daprheal.run", args: [{pods: [_bare, (_bare & {ns: "bonk", name: "bonk-crud-0", owner: "StatefulSet/bonk-crud", containers: ["crud"]})], rs: _rs, failRoll: ["aprende/Deployment/aprende-flagd"]}], holds: {code: 1, rolled: ["bonk/StatefulSet/bonk-crud"], marked: ["aprende.Deployment.aprende-flagd", "bonk.StatefulSet.bonk-crud"]}, why: "no error text is read: the next sweep reads whether the restart landed"},
	]
}

cases: "a roll whose answer was a timeout keeps its mark and fails the run, whatever the text": {
	suite: "daprheal"
	steps: [
		{call: "daprheal.run", args: [{pods: [_bare], rs: _rs, failRoll: ["aprende/Deployment/aprende-flagd"], rollError: "error: Timeout: request did not complete within requested timeout"}], holds: {code: 1, rolled: [], marked: ["aprende.Deployment.aprende-flagd"]}},
	]
}

cases: "a mark that cannot be written stops the roll: nothing is restarted that nothing remembers": {
	suite: "daprheal"
	steps: [
		{call: "daprheal.run", args: [{pods: [_bare], rs: _rs, readonlyState: true}], holds: {code: 1, rolled: [], marked: []}},
		{pick: ["err"], matches: "cannot be written: not rolled"},
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

cases: "a ReplicaSet that cannot be read leaves every mark in place: the inventory is incomplete, nothing is pruned, the run fails": {
	suite: "daprheal"
	steps: [
		{call: "daprheal.run", args: [{pods: [_bare], rs: _rs, failRs: true, marks: {"aprende.Deployment.aprende-flagd": 5, "aprende.Deployment.other": 45}}], holds: {code: 1, rolled: [], marked: ["aprende.Deployment.aprende-flagd", "aprende.Deployment.other"]}, why: "its mark was the live rollout's cooldown: pruned, the next sweep would restart the Deployment again"},
		{pick: ["err"], matches: "its ReplicaSet could not be read: not pruning marks"},
	]
}

cases: "marks that cannot be removed fail the run, healthy or not, so the host check shows it": {
	suite: "daprheal"
	steps: [
		{call: "daprheal.run", args: [{pods: [(_bare & {containers: ["flagd", "daprd"]})], rs: _rs, readonlyState: true, marks: {"aprende.Deployment.aprende-flagd": 45}}], holds: {code: 1, rolled: [], marked: ["aprende.Deployment.aprende-flagd"]}, why: "a mark left over would be read as the previous incident by the next outage"},
		{pick: ["err"], matches: "could not be removed"},
		{call: "daprheal.run", args: [{pods: [(_bare & {ns: "bonk", name: "bonk-crud-0", owner: "StatefulSet/bonk-crud", containers: ["crud"]})], readonlyState: true, marks: {"aprende.Deployment.aprende-flagd": 45, "bonk.StatefulSet.bonk-crud": 5}}], holds: {code: 1, marked: ["aprende.Deployment.aprende-flagd", "bonk.StatefulSet.bonk-crud"]}, why: "the stale mark of another workload cannot be removed while a bare pod is waiting: the run says so"},
	]
}

cases: "--dry-run makes no state folder and still says what it would roll": {
	suite: "daprheal"
	steps: [
		{call: "daprheal.run", args: [{pods: [_bare], rs: _rs, args: ["--dry-run"], noStateDir: true}], holds: {code: 0, stateCreated: false, out: "dapr-heal: would roll aprende/Deployment/aprende-flagd\n"}},
	]
}

cases: "a mark whose attempt is not on the workload (a reboot between the two) has the same patch sent again, cooldown or not, whatever else restarted it": {
	suite: "daprheal"
	steps: [
		{call: "daprheal.run", args: [{pods: [_bare], rs: _rs, marks: {"aprende.Deployment.aprende-flagd": 5}, markGeneration: {"aprende.Deployment.aprende-flagd": null}, attempt: {"aprende/Deployment/aprende-flagd": null}}], holds: {code: 0, rolled: ["aprende/Deployment/aprende-flagd"], ids: {"aprende/Deployment/aprende-flagd": "20260101T000000Z-1"}, marked: ["aprende.Deployment.aprende-flagd"]}, why: "the id patched is the mark's own: sending it twice changes nothing"},
		{pick: ["out"], matches: "attempt 20260101T000000Z-1 had not landed and was sent again"},
		{call: "daprheal.run", args: [{pods: [_bare], rs: _rs, marks: {"aprende.Deployment.aprende-flagd": 45}, markGeneration: {"aprende.Deployment.aprende-flagd": null}, attempt: {"aprende/Deployment/aprende-flagd": "someone-elses"}}], holds: {code: 0, rolled: ["aprende/Deployment/aprende-flagd"], ids: {"aprende/Deployment/aprende-flagd": "20260101T000000Z-1"}}, why: "another client's attempt, or restart, on the template is not this attempt: no clock is read"},
		{call: "daprheal.run", args: [{pods: [_bare], rs: _rs, marks: {"aprende.Deployment.aprende-flagd": 5}}], holds: {code: 0, rolled: []}, why: "the attempt is on the workload: it landed, the cooldown is waited out"},
		{call: "daprheal.run", args: [{pods: [_bare], rs: _rs, marks: {"aprende.Deployment.aprende-flagd": 5}, markGeneration: {"aprende.Deployment.aprende-flagd": null}, attempt: {"aprende/Deployment/aprende-flagd": null}, args: ["--dry-run"]}], holds: {code: 0, rolled: [], marked: ["aprende.Deployment.aprende-flagd"]}, why: "a dry run says it and sends nothing"},
	]
}

cases: "bare pods that none of the last attempt's covered are a new incident: they are rolled once the cooldown is out, though no sweep saw the healthy interval": {
	suite: "daprheal"
	steps: [
		{call: "daprheal.run", args: [{pods: [(_bare & {name: "new-pod", ageSec: 300})], rs: _rs, marks: {"aprende.Deployment.aprende-flagd": 45}, markPods: {"aprende.Deployment.aprende-flagd": ["gone-pod"]}}], holds: {code: 0, rolled: ["aprende/Deployment/aprende-flagd"]}, why: "made 5 minutes ago, after the 15 minutes ago the attempt's cooldown ended (the mark is 45 minutes old, the cooldown 30): not the roll's product, and the pod the mark covered is gone"},
		{pick: ["out"], matches: "a new incident"},
		{call: "daprheal.run", args: [{pods: [(_bare & {name: "new-pod", ageSec: 120})], rs: _rs, marks: {"aprende.Deployment.aprende-flagd": 5}, markPods: {"aprende.Deployment.aprende-flagd": ["gone-pod"]}}], holds: {code: 0, rolled: []}, why: "within the cooldown a new incident waits too"},
		{call: "daprheal.run", args: [{pods: [_bare, (_bare & {name: "new-pod"})], rs: _rs, marks: {"aprende.Deployment.aprende-flagd": 45}, markPods: {"aprende.Deployment.aprende-flagd": ["aprende-flagd-6898744c57-m6m77"]}}], holds: {code: 1, rolled: []}, why: "a pod it covered is still bare: the same incident, an error, not another roll"},
	]
}

cases: "a grep that fails stops the sweep before anything is rolled or any mark is deleted": {
	suite: "daprheal"
	steps: [
		{call: "daprheal.run", args: [{pods: [_bare], rs: _rs, failGrep: true}], holds: {code: 1, rolled: []}, why: "grep's status 2 was read as no match: a live mark deleted, the injector's readiness skipped"},
		{pick: ["err"], matches: "grep failed"},
		{call: "daprheal.run", args: [{pods: [(_bare & {ns: "bonk", name: "bonk-crud-0", owner: "StatefulSet/bonk-crud", containers: ["crud"]})], marks: {"aprende.Deployment.aprende-flagd": 5}, failGrep: true}], holds: {code: 1, rolled: [], marked: ["aprende.Deployment.aprende-flagd"]}, why: "the prune does not delete what it could not compare"},
	]
}

cases: "a workload that is not the one the pod's owner reference names is never restarted": {
	suite: "daprheal"
	steps: [
		{call: "daprheal.run", args: [{pods: [_bare], rs: _rs, uidMismatch: ["aprende/Deployment/aprende-flagd"]}], holds: {code: 1, rolled: [], marked: []}, why: "a pod writer's reference to a workload of the same name that was replaced"},
		{pick: ["err"], matches: "is not the workload the pod's owner reference names"},
		{call: "daprheal.run", args: [{pods: [(_bare & {ns: "bonk", name: "bonk-crud-0", owner: "StatefulSet/bonk-crud", containers: ["crud"]})], uidMismatch: ["bonk/StatefulSet/bonk-crud"]}], holds: {code: 1, rolled: []}},
	]
}

cases: "a workload whose template does not ask for a sidecar is never restarted": {
	suite: "daprheal"
	steps: [
		{call: "daprheal.run", args: [{pods: [_bare], rs: _rs, noDaprTemplate: ["aprende/Deployment/aprende-flagd"]}], holds: {code: 1, rolled: []}},
		{pick: ["err"], matches: "does not ask for a Dapr sidecar"},
	]
}

cases: "a workload that cannot be read is not rolled and fails the run": {
	suite: "daprheal"
	steps: [
		{call: "daprheal.run", args: [{pods: [_bare], rs: _rs, failLive: true}], holds: {code: 1, rolled: []}},
	]
}

cases: "a sort that fails is a failed sweep, not an empty one": {
	suite: "daprheal"
	steps: [
		{call: "daprheal.run", args: [{pods: [_bare], rs: _rs, failSort: true}], holds: {code: 1, rolled: []}},
		{pick: ["err"], matches: "could not be sorted"},
	]
}

cases: "the injector is read only when a pod is old enough to roll, and a failed read is its own error": {
	suite: "daprheal"
	steps: [
		{call: "daprheal.run", args: [{pods: [_bare], rs: _rs, injectorError: true}], holds: {code: 1, rolled: []}},
		{pick: ["err"], matches: "injector .* could not be read"},
		{call: "daprheal.run", args: [{pods: [(_bare & {ageSec: 30})], rs: _rs, injectorError: true}], holds: {code: 0, rolled: []}, why: "a young pod is not judged: the injector is not asked"},
	]
}

cases: "a forged line of the inventory cannot point a restart outside the swept namespaces nor at a malformed workload": {
	suite: "daprheal"
	steps: [
		{call: "daprheal.run", args: [{pods: [], extraOut: "other-ns|forged|Running||2020-01-01T00:00:00Z|StatefulSet/victim@11111111-2222-3333-4444-555555555555|app,\n"}], holds: {code: 1, rolled: []}, why: "an owner name with a newline in it ends a line and starts another, in a namespace nobody listed"},
		{pick: ["err"], matches: "'other-ns' is not a swept namespace"},
		{call: "daprheal.run", args: [{pods: [], extraOut: "aprende|forged|Running||2020-01-01T00:00:00Z|StatefulSet/Bad_Name@11111111-2222-3333-4444-555555555555|app,\n"}], holds: {code: 1, rolled: []}, why: "a name Kubernetes would not write"},
		{call: "daprheal.run", args: [{pods: [], extraOut: "aprende|forged|Running||2020-01-01T00:00:00Z|StatefulSet/ok@not-a-uid|app,\n"}], holds: {code: 1, rolled: []}, why: "a uid that is not 36 characters of hex and dashes"},
		{pick: ["err"], matches: "an owner or uid that is not a workload's name and a uid"},
	]
}

cases: "the pods a roll itself makes, still bare, are the same incident: an error, not a roll every cooldown for ever": {
	suite: "daprheal"
	steps: [
		{call: "daprheal.run", args: [{pods: [(_bare & {name: "replacement", ageSec: 1200})], rs: _rs, marks: {"aprende.Deployment.aprende-flagd": 45}, markPods: {"aprende.Deployment.aprende-flagd": ["old-pod"]}}], holds: {code: 1, rolled: [], marked: ["aprende.Deployment.aprende-flagd"]}, why: "made 20 minutes ago, 25 minutes after the attempt, inside its cooldown: the injector injects nothing for the replacement either"},
		{pick: ["err"], matches: "a pod it covered or made is still without its sidecar"},
	]
}

cases: "an older mark (no attempt in it) is honoured by its time: waited out inside the cooldown, replaced after it": {
	suite: "daprheal"
	steps: [
		{call: "daprheal.run", args: [{pods: [_bare], rs: _rs, oldMarks: {"aprende.Deployment.aprende-flagd": 5}}], holds: {code: 0, rolled: []}, why: "rolled 5 minutes ago by the version before this one"},
		{pick: ["out"], matches: "older mark, rolled less than 30 minutes ago: waiting"},
		{call: "daprheal.run", args: [{pods: [_bare], rs: _rs, oldMarks: {"aprende.Deployment.aprende-flagd": 45}}], holds: {code: 0, rolled: ["aprende/Deployment/aprende-flagd"]}},
	]
}

cases: "a mark that cannot be read is no mark that is dropped: the workload is left alone and the run fails": {
	suite: "daprheal"
	steps: [
		{call: "daprheal.run", args: [{pods: [_bare], rs: _rs, markIsDir: ["aprende.Deployment.aprende-flagd"]}], holds: {code: 1, rolled: []}, why: "sed could not read it: that was read as an old mark, dropped, and the workload rolled"},
		{pick: ["err"], matches: "could not be read: not rolled"},
	]
}

cases: "a mark's file is flushed before it is renamed and the folder after, and its temporary name is no workload's": {
	suite: "daprheal"
	steps: [
		{call: "daprheal.run", args: [{pods: [_bare], rs: _rs}], holds: {code: 0, rolled: ["aprende/Deployment/aprende-flagd"], marked: ["aprende.Deployment.aprende-flagd"]}},
		{pick: ["syncs.length", "syncs.0", "syncs.1"], matches: "^4,<dir>/state/\\.tmp\\.[0-9]+,<dir>/state$"},
	]
}

cases: "an attempt sent again refreshes the mark's time, so its cooldown starts when it landed": {
	suite: "daprheal"
	steps: [
		{call: "daprheal.run", args: [{pods: [_bare], rs: _rs, marks: {"aprende.Deployment.aprende-flagd": 45}, markGeneration: {"aprende.Deployment.aprende-flagd": null}, attempt: {"aprende/Deployment/aprende-flagd": null}}], holds: {code: 0, rolled: ["aprende/Deployment/aprende-flagd"], markAges: {"aprende.Deployment.aprende-flagd": 0}}, why: "45 minutes old before, now"},
	]
}

cases: "a mark whose id is not one of ours is never patched, and a sweep that finds the lock held ends clean": {
	suite: "daprheal"
	steps: [
		{call: "daprheal.run", args: [{pods: [_bare], rs: _rs, marks: {"aprende.Deployment.aprende-flagd": 45}, markAttempt: {"aprende.Deployment.aprende-flagd": "x\"y"}, attempt: {"aprende/Deployment/aprende-flagd": null}}], holds: {code: 1, rolled: []}},
		{pick: ["err"], matches: "not one of ours"},
		{call: "daprheal.run", args: [{pods: [_bare], rs: _rs, lockHeld: true}], holds: {code: 0, rolled: []}, why: "another sweep runs: this one reads and rolls nothing"},
		{pick: ["out"], matches: "another sweep holds"},
	]
}

cases: "bare pods of a later revision (the template changed since the attempt) are a new incident, though made inside the cooldown and carrying its annotation": {
	suite: "daprheal"
	steps: [
		{call: "daprheal.run", args: [{pods: [(_bare & {name: "later", ageSec: 1200})], rs: _rs, marks: {"aprende.Deployment.aprende-flagd": 45}, generation: {"aprende/Deployment/aprende-flagd": 9}}], holds: {code: 0, rolled: ["aprende/Deployment/aprende-flagd"]}, why: "the generation is 9, the attempt acknowledged 7: another rollout since. Made 20 minutes ago, inside the attempt's window by the clock: the old rule failed this for ever"},
		{pick: ["out"], matches: "template changed since its last attempt"},
		{call: "daprheal.run", args: [{pods: [(_bare & {name: "later", ageSec: 120})], rs: _rs, marks: {"aprende.Deployment.aprende-flagd": 5}, generation: {"aprende/Deployment/aprende-flagd": 9}}], holds: {code: 0, rolled: []}, why: "the cooldown is the clock's only part: inside it, wait"},
		{call: "daprheal.run", args: [{pods: [_bare], rs: _rs, marks: {"aprende.Deployment.aprende-flagd": 5}, attempt: {"aprende/Deployment/aprende-flagd": null}, generation: {"aprende/Deployment/aprende-flagd": 9}}], holds: {code: 0, rolled: []}, why: "a rollback that took the annotation off an acknowledged attempt is not an undelivered request: it is not sent again"},
	]
}

cases: "an attempt that landed but was never acknowledged is acknowledged at the workload's generation, and keeps its time": {
	suite: "daprheal"
	steps: [
		{call: "daprheal.run", args: [{pods: [_bare], rs: _rs, marks: {"aprende.Deployment.aprende-flagd": 5}, markGeneration: {"aprende.Deployment.aprende-flagd": null}}], holds: {code: 0, rolled: []}},
		{pick: ["acknowledged"], expect: [["aprende.Deployment.aprende-flagd"]]},
	]
}

cases: "a workload that has no bare pod but is still rolling out keeps its mark; a recovered or removed one loses it; an unreadable one keeps it and fails the run": {
	suite: "daprheal"
	steps: [
		{call: "daprheal.run", args: [{pods: [], rs: _rs, marks: {"aprende.Deployment.aprende-flagd": 5}, rollout: {"aprende/Deployment/aprende-flagd": "pending"}}], holds: {code: 0, rolled: [], marked: ["aprende.Deployment.aprende-flagd"]}, why: "a Recreate rollout: the old pod is terminating (not counted) and its replacement does not exist yet"},
		{pick: ["out"], matches: "still rolling out"},
		{call: "daprheal.run", args: [{pods: [(_bare & {ns: "bonk", name: "bonk-crud-0", owner: "StatefulSet/bonk-crud", containers: ["crud"]})], marks: {"aprende.Deployment.aprende-flagd": 5, "bonk.StatefulSet.bonk-crud": 5}, rollout: {"aprende/Deployment/aprende-flagd": "pending"}}], holds: {marked: ["aprende.Deployment.aprende-flagd", "bonk.StatefulSet.bonk-crud"]}, why: "the per-workload prune is the same: another workload being bare is not recovery"},
		{call: "daprheal.run", args: [{pods: [], rs: _rs, marks: {"aprende.Deployment.aprende-flagd": 5}}], holds: {code: 0, marked: []}, why: "ready and updated as wanted: recovered"},
		{call: "daprheal.run", args: [{pods: [], rs: _rs, marks: {"aprende.Deployment.aprende-flagd": 5}, rollout: {"aprende/Deployment/aprende-flagd": "gone"}}], holds: {code: 0, marked: []}, why: "the workload is gone: its mark goes"},
		{call: "daprheal.run", args: [{pods: [], rs: _rs, marks: {"aprende.Deployment.aprende-flagd": 5}, rollout: {"aprende/Deployment/aprende-flagd": "unreadable"}}], holds: {code: 1, marked: ["aprende.Deployment.aprende-flagd"]}},
	]
}

cases: "a lock error is an error and only contention is a clean skip; a creation time that cannot be read fails the sweep and prunes nothing": {
	suite: "daprheal"
	steps: [
		{call: "daprheal.run", args: [{pods: [_bare], rs: _rs, lockError: true}], holds: {code: 1, rolled: []}},
		{pick: ["err"], matches: "flock on .* failed"},
		{call: "daprheal.run", args: [{pods: [(_bare & {name: "odd", created: "yesterday"})], rs: _rs, marks: {"aprende.Deployment.aprende-flagd": 5}}], holds: {code: 1, rolled: [], marked: ["aprende.Deployment.aprende-flagd"]}, why: "an age that cannot be read was read as 'old enough to roll'"},
		{pick: ["err"], matches: "creation time 'yesterday' cannot be read"},
	]
}

cases: "a ReplicaSet name that is not a name is never an argument, and the ReplicaSet found must be the one the pod names": {
	suite: "daprheal"
	steps: [
		{call: "daprheal.run", args: [{pods: [(_bare & {owner: "ReplicaSet/--all"})], rs: _rs}], holds: {code: 1, rolled: []}},
		{pick: ["err"], matches: "its ReplicaSet name is not a name"},
		{call: "daprheal.run", args: [{pods: [(_bare & {ownerUid: "11111111-2222-3333-4444-555555555555"})], rs: _rs}], holds: {code: 1, rolled: []}, why: "a stale reference, or one a pod writer supplied: the ReplicaSet now of that name is another's"},
		{pick: ["err"], matches: "is not the one the pod names"},
	]
}
