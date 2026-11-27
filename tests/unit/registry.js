// What the plugins' cases call (tests/unit.ts): each namespace a module of an intent or of their
// runner (run) or its shell (flagsOf), identity pronto-identity's installer and brokers (identity.js), phone the broker's phone (identity/broker/phone.ts), otp its own codes' (identity/broker/otp.ts), idcore the broker's own decisions (identity/broker/core.ts), probe the
// measures of probes.js, cron release-cron's rules (release-cron/cron.js), cronlock its lock on an in-memory file system with links (cronlock.js), notes release-notes' (release-notes/notes.js), watch prod-watch's (prod-watch/watch.js), watchruns its cursor runs on a fake log (watchruns.js), alerts pronto-alerts' rules (alerts/inbox.js), alertsrun its driver on a fake Pub/Sub pull endpoint and a fake phone (alerts_run.js), prober pronto-probe's (probe/probe.js), runners runners' (runners/plan.js), and devflow the dev flow's rules (devflow/flow.js), inbox the suggestion inbox on a fake Plane (devflow.js), queue the Ready queue's verbs on it (devflow.js), ghboard GitHub Projects in the board's words (devflow/board/github.js), shop the stand-in apps the intents run on, as shops.js sets them up, android the Android terminal's compiler on pages of linkedom (android.js), androidScenarios its phone acceptance's pure rules (android/template/terminal/scenarios.ts), androidEmulator its emulator starter's (android/template/terminal/emulator.ts), migrations pronto-migrations' rules (migrations/plan.js), and mig those rules on an edited model (migrations.js), apigen pronto-api's generator, views, door and lint on a stand-in app (apigen.js), machine the cue wrapper's and vetted.ts's measures (machine.js), harness the flake filing of the scenarios' runner and the scenario selector's rule for files outside the app (harness.js), flagswait pronto-flags' wait for every flagd to say a written value (flags/live.nu await-live, run in nu on a stub of OFREP), ads pronto-ads' adapter, ad document service, policy and Caddyfile splice (ads.js), and native the shared native host contract (native/*.cue), its battery, and the Android host held to both (native.js), lessons pronto-lessons' step engine (lessons/app/lessons.js) and toy its toy adapter, courses and probes (lessons_toy.js), and lessonsdb its functions, plugin and emitted files on PGlite over a fixture course (lessons_db.js), and lessonsinstall the installer on a temporary app (lessons_install.js).
import * as stripe from '../../billing/connect.ts';
import * as billing from '../../billing/service.ts';
import * as billingNames from './billing.js';
import * as deploy from '../../gcp/deploy.ts';
import * as targets from '../../gcp/release_target.ts';
import * as identity from './identity.js';
import * as phone from '../../identity/broker/phone.ts';
import * as otp from '../../identity/broker/otp.ts';
import * as idcore from '../../identity/broker/core.ts';
import * as devflow from '../../devflow/flow.js';
import * as ghboard from '../../devflow/board/github.js';
import * as inbox from './devflow.js';
import * as queue from './devflow.js';
import * as run from '../../intents/run.ts';
import * as shell from '../../intents/shell.ts';
import * as probe from './probes.js';
import * as prober from '../../probe/probe.js';
import * as cron from '../../release-cron/cron.js';
import * as cronlock from './cronlock.js';
import * as notes from '../../release-notes/notes.js';
import * as watch from '../../prod-watch/watch.js';
import * as watchruns from './watchruns.js';
import * as alerts from '../../alerts/inbox.js';
import * as alertsrun from './alerts_run.js';
import * as runners from '../../runners/plan.js';
import * as shop from './shops.js';
import * as android from './android.js';
import * as native from './native.js';
import * as migrations from '../../migrations/plan.js';
import * as mig from './migrations.js';
import * as androidScenarios from '../../android/template/terminal/scenarios.ts';
import * as androidEmulator from '../../android/template/terminal/emulator.ts';
import * as apigen from './apigen.js';
import * as machine from './machine.js';
import * as harness from './harness.js';
import * as ads from './ads.js';
import * as flagswait from './flags_wait.js';
import * as fb from './facebook.js';
import * as lessons from '../../lessons/app/lessons.js';
import * as toy from './lessons_toy.js';
import * as lessonsdb from './lessons_db.js';
import * as lessonsinstall from './lessons_install.js';

export function registry(_suite) {
  return { stripe, billing, billingNames, devflow, ghboard, inbox, queue, deploy, targets, identity, idcore, phone, otp, fb, run, shell, probe, shop, cron, cronlock, notes, watch, watchruns, alerts, alertsrun, prober, runners, android, androidScenarios, androidEmulator, migrations, mig, apigen, machine, harness, ads, flagswait, native, lessons, toy, lessonsdb, lessonsinstall };
}
