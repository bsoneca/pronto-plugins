// What any pronto node's host holds, whatever it runs (node/host/README.md): a node that is a lab for
// hundreds of apps needs these bounds written once, with defaults, and each node only its own values.
// Written byte for byte into a repository by `bin/pronto-node --host`; a node's file unifies #Host with its values.
package schema

import "list"

#Host: {
	dockerGC: #DockerGC
	// Opt-in: a host that is not a k3s node (no kubectl, no Dapr) holds no repair timer.
	daprHeal?: #DaprHeal
	kubelet?: #Kubelet
	// Opt-in: a host that cannot reach a notification channel says none.
	diskWatch?: #DiskWatch
	// Opt-in: a host with no k3s names no workloads.
	critical?: #Critical
	// The alarm rings before the kubelet evicts: the kubelet evicts at (100 - evictionHard) percent used.
	if kubelet != _|_ {
		diskWatch?: thresholdPercent: <(100 - kubelet.evictionHard.nodefs) & <(100 - kubelet.evictionHard.imagefs)
	}
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
	// How the repair runs kubectl as root on the node: one of the supported launchers, which host.nu maps to a fixed command (an absolute
	// path under /usr/local/bin, root's), never a program the host JSON names.
	kubectl: *"k3s kubectl" | "kubectl"
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

// The host's own disk alarm (PRONTO-2061): every pod of the 2026-11-27 outage was evicted, alerting with them, so nothing said the
// disk was filling. A timer's job (disk-watch.sh) runs on the host, with no pod, Prometheus or tunnel to lose: it reads the use of each
// of `mounts` and posts to `notifyUrl` when one reaches `thresholdPercent`, once per crossing, and again every `renotifyMinutes` while
// it stays over. The URL must lead off the node (a channel behind the node's own tunnel is down with it), and is the only way the node
// reaches the operator, so it is said, with no default: a node names its channel. It is a secret (anyone holding it can post to the
// channel), so its settings file is readable by root alone.
#DiskWatch: {
	// Paths whose filesystems are read: two on one filesystem are one disk.
	mounts: *["/", "/var/lib/containerd", "/var/lib/rancher"] | [#Mount, ...#Mount]
	thresholdPercent: *75 | (int & >=10 & <=99)
	renotifyMinutes:  *360 | (int & >=5)
	// An https URL with no quote, backslash, space or control character (it is written single-quoted into a settings file that systemd parses).
	notifyUrl!: =~"^https://[^'\"\\\\\\s\\x00-\\x1f\\x7f]+$"
	// A systemd OnCalendar expression, every minute by default; one line and no backslash, as dockerGC's.
	onCalendar: *"minutely" | (string & =~"^[^\n\r\\\\]+$")
}

// Not under /home, /root, /run/user, /tmp, /var/tmp or /dev: the unit hides them (ProtectHome, PrivateTmp, PrivateDevices), so df would read the
// unit's own empty view and the alarm would watch the wrong disk.
#Mount: string & =~"^/[A-Za-z0-9._/-]*$" & !~"^/(home|root|run/user|tmp|var/tmp|dev)(/|$)"

// The workloads that must outlive an eviction (PRONTO-2061): the kubelet evicts the lowest priority first, and a pod with no
// priority class goes before a system one. host.nu only checks (a class is set by the workload's own manifest, in the repository that
// deploys it) and reports a workload that is gone, or runs under no system-*-critical class, as drift. Few on purpose: a node whose
// every pod is critical has none to evict first, which weakens eviction itself.
#Critical: {
	kubectl: *"k3s kubectl" | "kubectl"
	workloads!: list.MaxItems(8) & [#Workload, ...#Workload]
}

#Workload: {
	namespace!: =~"^[a-z0-9]([-a-z0-9]*[a-z0-9])?$" & !~"^studio-"
	kind:       *"Deployment" | "StatefulSet" | "DaemonSet"
	name!:      =~"^[a-z0-9]([-a-z0-9.]*[a-z0-9])?$"
}
