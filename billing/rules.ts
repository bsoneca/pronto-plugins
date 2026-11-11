// generated from billing/rules.cue by billing/rules_gen.ts — do not edit
// What a tenant's billing document may say, and the words an entitlement may use.
export const RULES = {
  "owner": "^[A-Za-z0-9_-]{43}$",
  "plan": {
    "id": "^[a-z][a-z0-9-]{0,31}$",
    "nameMax": 80,
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
  ]
} as const;
