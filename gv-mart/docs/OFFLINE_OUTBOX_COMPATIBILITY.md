# Offline outbox: additive-only payloads, forever

A technician's offline job queue (`src/lib/offline/db.ts`'s `outbox` table)
lives in on-device IndexedDB. A job can sit there for hours — queued before
the technician lost signal, synced long after — and now that the app
updates itself over the air (`src/lib/ota`), it can also sit there across
an app update: a job queued by today's bundle may not get replayed by
`runJob` (`src/lib/offline/sync.ts`) until a *later* bundle is running.

**The rule:** once a job `kind`'s payload shape ships, you may only ADD new
fields to it (at its `enqueue(...)` call site in `services/technician.ts`,
and to its entry in `src/lib/offline/outboxContract.ts`). Never remove,
rename, or repurpose an existing field. `runJob` must keep working for a
payload that has every field *up to* some past version and nothing past
that — because that's exactly what an old, already-queued job looks like
next to a replayer that's since been updated.

`outboxContract.ts`'s `OUTBOX_REQUIRED_FIELDS` is the enforced contract: a
snapshot of every field a kind has ever required, extracted straight from
the real call sites. `runJob` checks every payload against it before doing
anything else (`assertRequiredFields`), and `outboxContract.test.ts` pins
the whole table to a golden snapshot — if a future change drops a field
from the list (meaning some payload stopped including it), that test fails.

**What this does NOT need:** a version check or branch in `runJob`. The
`payloadVersion` field on each job (`outbox.ts`'s `enqueue`) is for
diagnostics only — telling you which bundle wrote a stuck job — never a
signal the replayer acts on. If you ever find yourself writing
`if (job.payloadVersion >= N) { ... }`, that's a sign the change you're
making isn't additive and needs a new `OutboxKind` instead of changing an
existing one's shape.
