package unit

// The plugins' suites, each a check of the plugins tree (.github/workflows/ci.yml): the intents
// (docs/intents.md) and their runner, pronto-identity's installer, the release target code (gcp/release_target.ts) and release-cron's rules (release-cron/cron.js).
#Suite: "stripe" | "deploy" | "release" | "runner" | "identity" | "targets" | "cron"
