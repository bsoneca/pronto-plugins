// What any pronto node's host holds, whatever it runs (node/host/README.md): a node that is a lab for
// hundreds of apps needs these bounds written once, with defaults, and each node only its own values.
// Written byte for byte into a repository by `bin/pronto-node --host`; a node's file unifies #Host with its values.
package schema

#Host: {
	dockerGC: #DockerGC
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
