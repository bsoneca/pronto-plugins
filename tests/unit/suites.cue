package unit

// The plugins' suites, each a check of the plugins tree (.github/workflows/ci.yml): the intents
// (docs/intents.md) and their runner, pronto-identity's installer, the release target code (gcp/release_target.ts) release-cron's rules (release-cron/cron.js), release-notes' (release-notes/notes.js), prod-watch's (prod-watch/watch.js) and runners' (runners/plan.js), pronto-probe's (probe/probe.js) and the Android terminal's compiler (android/template/terminal/compile.js), the dev flow's (devflow/flow.js), and pronto-migrations' (migrations/plan.js).
#Suite: "stripe" | "billing" | "deploy" | "release" | "runner" | "identity" | "targets" | "cron" | "runners" | "notes" | "fingerprint" | "noise" | "triage" | "android" | "probe" | "devflow" | "migrations" | "api" | "machine"
