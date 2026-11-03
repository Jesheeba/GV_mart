# String-literal / SQL-syntax review — 20261204170000_address_sub_area_field.sql

Scope: this pass checks ONLY string-literal escaping, dollar-quote balance, embedded-text
fidelity and basic SQL syntax (declared-vs-used variables, matching begin/end) — security is
covered separately in `.review-security.md`. Re-derived fresh against the final renamed files;
findings below were re-checked programmatically, not carried forward from any earlier draft.

**Honesty note on independence:** this agent is a forked session and is hard-restricted from
spawning subagents (tool-level rule, not a project-rule choice). So while this pass used a
different method than the original self-review (programmatic quote/tag/variable extraction
across every file, re-run after the rename, rather than eyeballing), it is still the same
underlying agent, not a second reviewer. Flagging that plainly rather than calling it
"independent" when the constraint prevents true independence.

## Files in scope (post-rename)
- `supabase/migrations/20261204170000_address_sub_area_field.sql`
- `supabase/ops/20261204170000_address_sub_area_field.apply.sql`
- `supabase/ops/20261204170000_address_sub_area_field.apply.dryrun.sql`
- `supabase/rollbacks/20261204170000_address_sub_area_field.rollback.sql`
- `supabase/migrations/20261204170000_address_sub_area_field.rollback_exercise.apply.dryrun.sql`
- `supabase/migrations/20261204170000_address_sub_area_field.post_apply_verify.sql`
- `supabase/ops/20261204170000_address_sub_area_field.capture_live_pins.sql` (new, item 3)

## Method
1. Extracted every line containing a single quote from each file and read each one — every
   `'...'` literal is either a plain unparameterized string with no embedded apostrophe, or the
   one `comment on column` literal, whose embedded apostrophe (`form's`) is correctly doubled
   (`form''s`).
2. No dynamic SQL/string concatenation with any caller-supplied or table-derived value appears
   anywhere — every `||` concatenation builds diagnostic/error text from values already
   validated as uuid/text/int by the query that produced them, never raw user input. No
   injection surface exists in these files (contrast with e.g. `find_duplicate_contacts`,
   which takes a caller-supplied search term and needs this kind of review for that reason;
   these files take no parameters at all).
3. Dollar-quote tag balance, counted programmatically (`grep -o`, not visual scan):
   - `apply.sql` / `apply.dryrun.sql`: `$apply$` ×2, `$migration$` ×2 each — balanced.
   - `rollback_exercise.apply.dryrun.sql`: `$rollback_proof$` ×2 — balanced.
   - `post_apply_verify.sql`: `$verify$` ×2 — balanced.
4. The `$migration$ ... $migration$` block embedded in both `apply.sql` and `apply.dryrun.sql`
   was diffed byte-for-byte (CR-stripped) against the actual committed
   `20261204170000_address_sub_area_field.sql` file: **match: true** in both, confirmed after
   the rename (this re-verifies what the sed rename touched didn't corrupt the embedded copy —
   it didn't, since the migration body itself never contained its own timestamp).
5. The pinned sha256 (`1d1cdf72e10adfb0d1051f7930c89f2fab4e38c2ff755dfe897d74dcd986a53a`) was
   independently recomputed from the post-rename migration file and matches what's hardcoded in
   both scripts — unchanged from before the rename, as expected (only the filename changed, not
   the migration body).
6. Declared-vs-used plpgsql variable names cross-checked in all four `do $...$` blocks
   (`apply.sql`, `apply.dryrun.sql`, `rollback_exercise...`, `post_apply_verify.sql`) — every
   variable used is declared; no typos, no undeclared-variable references. (Two apparent
   mismatches from an automated grep turned out to be false positives from the check's own
   regex — `v_addr_md5_*` truncated by a digit-boundary bug in the pattern, and
   `v_master`/`v_sales`/`v_tech`/`v_cust` declared together on one semicolon-separated line
   that the same pattern only matched the first of — read by eye afterward and confirmed
   correctly declared in both cases.)
7. `capture_live_pins.sql` (new): a single read-only `select`, no `do` block, no DML/DDL of any
   kind — confirmed by reading the whole file; nothing to check for balance since it has no
   control-flow blocks.

## Findings

**None.** No string-literal escaping errors, no unbalanced dollar-quoting, no embedded-text
drift, no undeclared-variable bugs, in any of the 7 files in scope.
