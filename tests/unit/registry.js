// What the plugins' cases call (tests/unit.ts): each namespace a module of an intent or of their
// runner (run) or its shell (flagsOf), identity pronto-identity's installer and brokers (identity.js), phone the broker's phone (identity/broker/phone.ts), probe the
// measures of probes.js, cron release-cron's rules (release-cron/cron.js), notes release-notes' (release-notes/notes.js), watch prod-watch's (prod-watch/watch.js), prober pronto-probe's (probe/probe.js), runners runners' (runners/plan.js), and devflow the dev flow's rules (devflow/flow.js), shop the stand-in apps the intents run on, as shops.js sets them up, android the Android terminal's compiler on pages of linkedom (android.js), and androidScenarios its phone acceptance's pure rules (android/template/terminal/scenarios.ts).
import * as stripe from '../../billing/connect.ts';
import * as billing from '../../billing/service.ts';
import * as deploy from '../../gcp/deploy.ts';
import * as targets from '../../gcp/release_target.ts';
import * as identity from './identity.js';
import * as phone from '../../identity/broker/phone.ts';
import * as devflow from '../../devflow/flow.js';
import * as run from '../../intents/run.ts';
import * as shell from '../../intents/shell.ts';
import * as probe from './probes.js';
import * as prober from '../../probe/probe.js';
import * as cron from '../../release-cron/cron.js';
import * as notes from '../../release-notes/notes.js';
import * as watch from '../../prod-watch/watch.js';
import * as runners from '../../runners/plan.js';
import * as shop from './shops.js';
import * as android from './android.js';
import * as androidScenarios from '../../android/template/terminal/scenarios.ts';

export function registry(_suite) {
  return { stripe, billing, devflow, deploy, targets, identity, phone, run, shell, probe, shop, cron, notes, watch, prober, runners, android, androidScenarios };
}
