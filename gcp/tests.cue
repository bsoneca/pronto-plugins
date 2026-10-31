package gcp

import (
	"encoding/json"
	"strings"
)

_t: #Host & {app: "chess", project: "chess-prod", region: "southamerica-east1"}
_rules: json.Unmarshal(_t.files[".say.json"].text).say.release.rulemap
_live: [for c in _rules.gcp.cmds {c.do}]
_preview: [for c in _rules["gcp-preview"].cmds {c.do}]

// The live release: the image built and checked, sayt's ceremony, then the
// version deployed by digest and the tag pushed, the last two not on --snapshot.
livePlatform: _rules.gcp.platform & "gcp"
liveBuilds: _live[0] & "use ./gcp/gcp.nu; gcp image chess"
liveCeremony: _rules.gcp.cmds[1].use & "./release.nu"
liveDeploys: _live[2] & "if ($env.SAY_RELEASE_ARGS_SNAPSHOT? | is-empty) { use semver.nu [tag-on-head]; use ./gcp/gcp.nu; gcp deploy chess chess (tag-on-head | path basename) --project chess-prod --region southamerica-east1 --repository pronto --max-scale 3 --memory 512Mi }"
livePushes: strings.Contains(_live[3], "git push origin $tag") & true

// The preview: sayt's default platform, its own service, no ceremony.
previewPlatform: _rules["gcp-preview"].platform & "preview"
previewDeploys: _preview[1] & "use ./gcp/gcp.nu; gcp deploy chess chess-preview preview --project chess-prod --region southamerica-east1 --repository pronto --max-scale 3 --memory 512Mi"
previewNoCeremony: len([for c in _rules["gcp-preview"].cmds if c.use != _|_ {c}]) & 0

// A custom address is the door's origin.
_o: #Host & {app: "chess", project: "chess-prod", origin: "https://chess.example"}
originPassed: strings.HasSuffix(json.Unmarshal(_o.files[".say.json"].text).say.release.rulemap["gcp-preview"].cmds[1].do, "--origin https://chess.example") & true

// gcloud pinned; the module and the shim written; .say.json merged.
pinned: strings.Contains(_t.files[".config/mise/conf.d/gcp.toml"].text, "gcloud = { version = \"589.0.0\", depends = [\"python\"] }") & true
module: strings.Contains(_t.files["gcp/gcp.nu"].text, "export def deploy [") & true
merged: [for p, f in _t.files if f.merge != _|_ if f.merge {p}] & [".say.json"]
seeded: [for p, f in _t.files if f.seed {p}] & [".goreleaser.yaml"]

// The image never carries the developer's certificates, and a server app is refused.
noCerts: strings.Contains(_t.files["gcp/gcp.nu"].text, "--exclude ./.certs") & true
doorOnly: strings.Contains(_t.files["gcp/gcp.nu"].text, "pronto-gcp releases a door alone") & true

// Plain `release` is the preview alone: sayt's builtin ceremony is off.
previewAlone: _rules.builtin & null
