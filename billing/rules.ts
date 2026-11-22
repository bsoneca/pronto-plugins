// generated from billing/rules.cue by billing/rules_gen.ts — do not edit
// What a tenant's billing document may say, and the words an entitlement may use.
export const RULES = {
  "owner": "^[A-Za-z0-9_-]{43}$",
  "plan": {
    "id": "^[a-z][a-z0-9-]{0,31}$",
    "nameMax": 80,
    "nameText": "[^\\t\\n\\f\\r ]",
    "interval": [
      "month",
      "year"
    ]
  },
  "currencies": [
    "usd",
    "brl",
    "eur",
    "gbp"
  ],
  "price": {
    "min": 50,
    "max": 1000000
  },
  "trial": {
    "monthsMin": 1,
    "monthsMax": 23,
    "remindDays": 7
  },
  "trialStates": [
    "running",
    "cancelled",
    "converted",
    "ended",
    "failed"
  ],
  "claimStates": [
    "claimed",
    "done"
  ],
  "claimTransitions": [
    {
      "event": "claim",
      "from": "absent",
      "token": "none",
      "to": "claimed"
    },
    {
      "event": "complete",
      "from": "claimed",
      "token": "holder",
      "to": "done"
    },
    {
      "event": "release",
      "from": "claimed",
      "token": "holder",
      "to": "absent"
    },
    {
      "event": "remember",
      "from": "absent",
      "token": "none",
      "to": "done"
    },
    {
      "event": "remember",
      "from": "claimed",
      "token": "none",
      "to": "done"
    },
    {
      "event": "remember",
      "from": "done",
      "token": "none",
      "to": "done"
    },
    {
      "event": "expire",
      "from": "claimed",
      "token": "none",
      "to": "absent"
    },
    {
      "event": "expire",
      "from": "done",
      "token": "none",
      "to": "absent"
    },
    {
      "event": "invalidate",
      "from": "done",
      "token": "none",
      "to": "absent"
    }
  ],
  "claimSweep": 100,
  "claimRetentionMs": 604800000,
  "claimLeaseMs": 120000,
  "routeLimits": {
    "perClient": 30,
    "global": 120,
    "bodyMax": 4096,
    "windowMs": 60000
  },
  "bodyLimits": {
    "request": 4096,
    "webhook": 262144
  },
  "doorLookupTimeoutMs": 300,
  "brokerRole": "billing"
} as const;
