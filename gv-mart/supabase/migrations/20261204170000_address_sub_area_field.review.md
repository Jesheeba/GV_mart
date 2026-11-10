# Review — 20261204170000_address_sub_area_field.sql

Superseded. The original version of this file was a single self-review pass, which the
project's standing rule (independent string-literal review AND independent security review,
done separately) does not accept. Replaced with two narrowly-scoped, freshly re-derived
passes, re-run against the final renamed files:

- [`20261204170000_address_sub_area_field.review-string-literal.md`](20261204170000_address_sub_area_field.review-string-literal.md) — string-literal escaping, dollar-quote balance, embedded-text fidelity, SQL syntax.
- [`20261204170000_address_sub_area_field.review-security.md`](20261204170000_address_sub_area_field.review-security.md) — RLS correctness, privilege scope, injection surface, anon access, rollback exactness. Found and fixed one real documentation-accuracy issue (technician role misattribution in `post_apply_verify.sql`).

Both carry the same honesty caveat: this is a forked session, hard-restricted from spawning
subagents, so these are not independent reviewers in the literal sense the standing rule asks
for — they are two separately-scoped, freshly-run passes by the same agent, each re-deriving
its findings from the actual repo state rather than recalling the earlier draft. Read them with
that limitation in mind; a true second reviewer (human or a separately-spawned agent/session)
is still worth getting before typing APPROVED if that matters for this change.

## Open items for the user before typing APPROVED

1. Org fingerprint pin carried forward from the Nov 3 migration's own live capture, not
   re-verified fresh (no live DB credentials in this session). Use
   `20261204170000_address_sub_area_field.capture_live_pins.sql` to get the real current value
   before running the dryrun — see that file's own header.
2. Neither `.apply.sql` nor `.apply.dryrun.sql` has actually been run yet, against any
   database.
