package firebase

import (
	"encoding/json"
	"list"
	"strings"
)

_t: #Host & {app: "comic", project: "comic-prod"}
_rules: json.Unmarshal(_t.files[".say.json"].text).say.release.rulemap
_live: [for c in _rules.firebase.cmds {c.do}]
_preview: [for c in _rules["firebase-preview"].cmds {c.do}]

// The live release: pronto's bundle, the site, sayt's ceremony, then this
// machine deploys hosting alone and pushes the tag.
livePlatform: _rules.firebase.platform & "firebase"
liveBundles: strings.Contains(_live[0], "bundle.ts) . --omnishell") & true
liveAssembles: strings.Contains(_live[1], "use ./firebase/site.nu; site (run-mise exec -- cue export . -e") & true
liveCeremony: _rules.firebase.cmds[2].use & "./release.nu"
liveDeploys: _live[3] & "if ($env.SAY_RELEASE_ARGS_SNAPSHOT? | is-empty) { use tools.nu [run-mise]; run-mise exec -- firebase deploy --only hosting --project comic-prod --non-interactive }"
livePushes: strings.Contains(_live[4], "git push origin $tag") & true

// The preview: sayt's default platform, the same site, an expiring channel, no
// ceremony and so no tag.
previewPlatform: _rules["firebase-preview"].platform & "preview"
previewDeploys: _preview[2] & "use tools.nu [run-mise]; run-mise exec -- firebase hosting:channel:deploy preview --project comic-prod --expires 7d --non-interactive"
previewNoCeremony: len([for c in _rules["firebase-preview"].cmds if c.use != _|_ {c}]) & 0

// Hosting alone, the page answering every address; the app's once written.
_hosting: json.Unmarshal(_t.files["firebase.json"].text)
hostingOnly: [for k, _ in _hosting {k}] & ["hosting"]
hostingSite: _hosting.hosting & {public: "dist/firebase", rewrites: [{source: "**", destination: "/index.html"}]}
seeded: list.SortStrings([for p, f in _t.files if f.seed {p}]) & [".goreleaser.yaml", "firebase.json"]
merged: [for p, f in _t.files if f.merge != _|_ if f.merge {p}] & [".say.json"]
cliPinned: strings.Contains(_t.files[".config/mise/conf.d/firebase.toml"].text, "\"npm:firebase-tools\" = \"15.32.1\"") & true
noWorkflow: (_t.files[".github/workflows/firebase.yml"] == _|_) & true

// A CI identity: the tag is the deploy, keyless, to the named site.
_c: #Host & {
	app:        "comic"
	project:    "comic-prod"
	site:       "comic-site"
	channel:    "staging"
	ciProvider: "projects/123456/locations/global/workloadIdentityPools/github/providers/comic"
	ciAccount:  "deployer@comic-prod.iam.gserviceaccount.com"
}
_cRules: json.Unmarshal(_c.files[".say.json"].text).say.release.rulemap
ciNoLocalDeploy: len([for c in _cRules.firebase.cmds if strings.Contains(c.do, "firebase deploy") {c}]) & 0
_workflow: _c.files[".github/workflows/firebase.yml"].text
ciAuth: strings.Contains(_workflow, "workload_identity_provider: projects/123456/locations/global/workloadIdentityPools/github/providers/comic") & true
ciDeploys: strings.Contains(_workflow, "firebase deploy --only hosting:comic-site --project comic-prod --non-interactive") & true
ciSnapshot: strings.Contains(_workflow, "sayt release@firebase --snapshot") & true
ciPreviewSite: [for c in _cRules["firebase-preview"].cmds {c.do}][2] & "use tools.nu [run-mise]; run-mise exec -- firebase hosting:channel:deploy staging --project comic-prod --site comic-site --expires 7d --non-interactive"
ciSiteNamed: json.Unmarshal(_c.files["firebase.json"].text).hosting.site & "comic-site"

// Plain `release` is the preview alone: sayt's builtin ceremony is off.
previewAlone: _rules.builtin & null
