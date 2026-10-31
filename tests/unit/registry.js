// What the plugins' cases call (tests/unit.ts): each namespace a module of an intent or of their
// runner (run) or its shell (flagsOf), identity pronto-identity's installer (identity.js), probe the
// measures of probes.js, and shop the stand-in apps the intents run on, as shops.js sets them up.
import * as stripe from '../../billing/connect.ts';
import * as deploy from '../../gcp/deploy.ts';
import * as identity from './identity.js';
import * as run from '../../intents/run.ts';
import * as shell from '../../intents/shell.ts';
import * as probe from './probes.js';
import * as shop from './shops.js';

export function registry(_suite) {
  return { stripe, deploy, identity, run, shell, probe, shop };
}
