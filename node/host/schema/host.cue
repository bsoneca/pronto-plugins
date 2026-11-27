// What any pronto node's host holds, whatever it runs (node/host/README.md): a node that is a lab for
// hundreds of apps needs these bounds written once, with defaults, and each node only its own values.
// Written byte for byte into a repository by `bin/pronto-node --host`; a node's file unifies #Host with its values.
package schema

#Host: {
	dockerGC: #DockerGC
}

// The node's Docker disk, kept bounded: each release@k8s bakes its images with the node's dockerd
// (`bake --load`), tags them localhost:<port>/<app>-<service> and pushes them to the node's registry, and
// nothing removed them, until Docker held 200G and the node went down. A timer's job (docker-gc.sh)
// removes the tags refPattern names once last tagged over minAgeHours ago (a release's own are minutes old;
// the image's creation time is the epoch, so age is read from the tag), dangling images, and build cache
// past buildCacheGB; it fails when Docker still holds more than capGB.
#DockerGC: {
	minAgeHours: *6 | (int & >=1)
	// A bash ERE, kept inside single quotes in /etc/pronto/docker-gc.env, so it holds none.
	refPattern:   *"^localhost:[0-9]+/" | (string & =~"^\\^[^']*$")
	buildCacheGB: *40 | (int & >0)
	// The default is not kept when it would not exceed the cache: a larger cache needs a larger cap said.
	capGB: (*120 | int) & >buildCacheGB
	// A systemd OnCalendar expression.
	// One line: it is written into a unit file, where a newline would start another setting.
	onCalendar: *"hourly" | (string & =~"^[^\n]+$")
}
