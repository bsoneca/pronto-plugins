// What any pronto node's host holds, whatever it runs (node/host/README.md): a node that is a lab for
// hundreds of apps needs these bounds written once, with defaults, and each node only its own values.
// Written byte for byte into a repository by `bin/pronto-node --host`; a node's file unifies #Host with its values.
package schema

#Host: {
	dockerGC: #DockerGC
	// Opt-in: a host that is not a k3s node (no kubectl, no Dapr) holds no repair timer.
	daprHeal?: #DaprHeal
	kubelet?: #Kubelet
}

// The node's kubelet, set by kubelet.nu (README.md, "The node host"): how full the disk may get before pods
// are evicted, and how much a log may grow. k3s's defaults evict at 5% free (nodefs and imagefs only) and then reclaim 10% more, about 39G
// of a 387G disk, which evicting every pod did not free (the 2026-11-27 outage), so the amounts are absolute.
// A partial --eviction-hard drops the kubelet's other defaults (memory.available<100Mi, nodefs.inodesFree<5%, ...), so
// every threshold is written, and none has a default: a node says each, and a map missing one is refused.
#Kubelet: {
	// How many pods the node runs: said, with no default, since a default would write k3s's 110 over a node that runs
	// more and strand its pods Pending. The node's pod range bounds it: k3s gives the node a /24 of the cluster CIDR,
	// 253 addresses; a limit past it needs a wider range.
	maxPods!: int & >=110 & <=#PodAddresses

	// The thresholds under which the kubelet evicts: percent of the filesystem (or its inodes) free, and memory left.
	evictionHard!: {
		memory!:        =~"^[1-9][0-9]{1,3}Mi$"
		nodefs!:        #Percent
		nodefsInodes!:  #Percent
		imagefs!:       #Percent
		imagefsInodes!: #Percent
	}
	// What the kubelet frees once it evicts, beside the threshold, absolute.
	evictionMinimumReclaim!: {
		nodefs!:  =~"^[1-9][0-9]?Gi$"
		imagefs!: =~"^[1-9][0-9]?Gi$"
	}
	// Image garbage collection starts at high percent of the image filesystem used and stops at low, both before eviction.
	imageGC!: {
		high!: int & <=(95 - evictionHard.nodefs) & <=(95 - evictionHard.imagefs)
		low!:  int & >0 & <high
	}
	// The container log: each file's size, and how many the runtime keeps.
	containerLogMaxSize:  *"10Mi" | =~"^[1-9][0-9]{0,3}(Ki|Mi)$"
	containerLogMaxFiles: *5 | (int & >=2 & <=20)
}

// The addresses a node's pod range holds (k3s gives the node a /24 of the cluster CIDR): the most pods it can run.
#PodAddresses: 253

// Percent of a filesystem: at most a fifth free, so the kubelet evicts late but before the disk is full.
#Percent: int & >=1 & <=20

// The node's Docker disk, kept bounded: each release@k8s bakes its images with the node's dockerd
// (`bake --load`), tags them localhost:<port>/<app>-<service> and pushes them to the node's registry, and
// nothing removed them, until Docker held 200G and the node went down. A timer's job (docker-gc.sh)
// removes the tags refPattern names once last tagged over minAgeHours ago (a release's own are minutes old;
// the image's creation time is the epoch, so age is read from the tag), dangling images, and build cache
// past buildCacheGB; it fails when Docker still holds more than capGB.
#DockerGC: {
	minAgeHours: *6 | (int & >=1)
	// A bash ERE, kept inside single quotes in /etc/pronto/docker-gc.env, so it holds none.
	refPattern:   *"^localhost:[0-9]+/" | (string & =~"^\\^[^'\n]*$")
	buildCacheGB: *40 | (int & >0)
	// The default is not kept when it would not exceed the cache: a larger cache needs a larger cap said.
	capGB: (*120 | int) & >buildCacheGB
	// A systemd OnCalendar expression.
	// One line, and no backslash (a trailing one continues the line and breaks the timer): it is written into a unit file,
	// where a newline would start another setting.
	onCalendar: *"hourly" | (string & =~"^[^\n\r\\\\]+$")
}

// The Dapr sidecar kept on every pod that asks for one (PRONTO-2191): a pod created while the Dapr injector was down (the
// 2026-11-27 disk outage) is admitted with no daprd and stays so, and every call to its app's Dapr port is refused. A timer's job
// (dapr-heal.sh) finds each pod annotated dapr.io/enabled=true with no daprd container and rolls its Deployment, StatefulSet or
// DaemonSet once the injector has a ready replica, so the injector adds the sidecar; it does not touch a Job's pod or a pod of its
// own, looks only in `namespaces`, and rolls a workload at most once per cooldownMinutes; a pod created after that roll and still
// bare is an error, never a second roll.
#DaprHeal: {
	// The words that run kubectl as root on the node, kept inside single quotes in /etc/pronto/dapr-heal.env, so no quote.
	kubectl: *"k3s kubectl" | (string & =~"^[A-Za-z0-9_./-]+( [A-Za-z0-9_./-]+)*$")
	// The operator's namespaces, the only ones swept: a tenant's (Studio's `studio-<owner>-<app>-<hash>`) must not be able to
	// trigger a roll or turn the check red, and dapr-system and the system namespaces are not apps. Names, not patterns; none is assumed (a node says its own, as `#Kubelet.maxPods`).
	namespaces!: [#OperatorNamespace, ...#OperatorNamespace]
	// A pod younger than this is not judged.
	graceSeconds: *120 | (int & >=30)
	// How long after rolling a workload it is not rolled again.
	cooldownMinutes: *30 | (int & >=5)
	// A systemd OnCalendar expression; every five minutes by default. One line and no backslash, as dockerGC's.
	onCalendar: *"*:0/5" | (string & =~"^[^\n\r\\\\]+$")
}

#OperatorNamespace: string & =~"^[a-z0-9]([-a-z0-9]*[a-z0-9])?$" & !~"^(default|dapr-system|kube-system|kube-public|kube-node-lease)$" & !~"^studio-"
