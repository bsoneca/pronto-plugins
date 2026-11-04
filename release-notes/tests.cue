package releasenotes

_t: #Host

// An opt-in writes the driver and its rules, and seeds nothing.
written: [for p, f in _t.files if !f.seed {p}] & ["release-notes/release-notes.ts", "release-notes/notes.js"]
seeded: [for p, f in _t.files if f.seed {p}] & []
