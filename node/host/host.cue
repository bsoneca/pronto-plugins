// The host files of a pronto node (README.md, "The node host"): the Docker cleanup, as the files a
// repository that holds a node's values vendors, byte for byte and with no header, by
// `bin/pronto-node --host <dir>`. Its harness.sh compares them with this repository's at a pin.
@extern(embed)

package host

_dockerGC: _ @embed(file="docker-gc.sh", type=text)
_daprHeal: _ @embed(file="dapr-heal.sh", type=text)
_diskWatch: _ @embed(file="disk-watch.sh", type=text)
_hostNu:   _ @embed(file="host.nu", type=text)
_kubelet:  _ @embed(file="kubelet.nu", type=text)
_schema:   _ @embed(file="schema/host.cue", type=text)

// The files, from the root of the directory they are written into.
#Files: {
	"node-host/docker-gc.sh":    _dockerGC
	"node-host/dapr-heal.sh":    _daprHeal
	"node-host/disk-watch.sh":   _diskWatch
	"node-host/host.nu":         _hostNu
	"node-host/kubelet.nu":      _kubelet
	"node-host/schema/host.cue": _schema
}

#Host: {
	files: {
		for path, body in #Files {(path): {seed: false, text: body}}
	}
}
