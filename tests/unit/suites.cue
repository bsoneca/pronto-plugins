package unit

// The plugins' suites, each a check of the plugins tree (.github/workflows/ci.yml): the intents
// (docs/intents.md) and their runner, pronto-identity's installer, the release target code (gcp/release_target.ts) release-cron's rules (release-cron/cron.js) and runners' (runners/plan.js).
#Suite: "stripe" | "billing" | "deploy" | "release" | "runner" | "identity" | "targets" | "cron" | "runners"
