# Security review — 20261204170000_address_sub_area_field.sql

Scope: this pass checks ONLY RLS correctness, privilege/grant scope, injection surface and
anon access — string-literal/syntax correctness is covered separately in
`.review-string-literal.md`. Re-derived fresh by reading the actual live RLS/helper-function
definitions in this repo (not recalled from memory or the earlier self-review).

**Honesty note on independence:** same constraint as the string-literal pass — this agent is a
forked session hard-restricted from spawning subagents, so this is not a second reviewer. What
makes this pass meaningfully different from the earlier self-review: it re-reads the actual
`is_staff()`/`is_sales_staff()` function bodies and the actual `addresses` RLS policy set from
the committed migrations, rather than asserting their behavior from recollection — and it found
and fixed a real inaccuracy as a result (below).

## What this migration actually changes (re-confirmed by reading the file, not assumed)

`alter table public.addresses add column if not exists sub_area text;` plus one `comment on
column`. Nothing else. No `grant`, no `revoke`, no `create policy`, no function, no trigger.

## Finding 1 (real, fixed): post_apply_verify.sql misattributed technician read access

**Before this pass:** the file's closing `INFO expected shape` line claimed "master/sales_admin/
technician see rows per the existing addresses_select_staff/addresses_select_own policies."

**Checked against the actual live definitions** (`20261010110000_staff_helpers_require_active.sql`):
```sql
create or replace function public.is_staff() ... as $$
  select exists (select 1 from public.profiles
    where id = auth.uid() and (role in ('master', 'operation_admin') or (role = 'sales_admin' and is_active)))
$$;
```
`is_staff()` does **not** include `technician`. `addresses_select_staff` (`for select using
(org_id = current_org_id() and is_staff())`) therefore does not grant technicians anything.

**Correction (caught by an independent reviewer pass, this agent's first version of this
finding was itself wrong):** this review originally claimed technician read access to
`addresses` comes from two policies — `addresses_select_own_technician` (job-scoped) AND
`addresses_select_technician_search` (org-wide, `current_role() = 'technician'`,
`20260704130000_technician_customer_search_rls.sql`). That second policy existed once but was
**dropped, not replaced**, by `20260716100000_restrict_technician_customer_search_rls.sql` —
verified by reading that migration directly: it explicitly removes
`addresses_select_technician_search` (and `customers_select_technician_search`) as a
privacy/data-exposure fix ("a technician can read any customer's name/phone/address in the
org, not just customers they are assigned to or have previously serviced") and its header says
plainly "do not replace them with a new policy." So today, technician read access to
`addresses` comes **only** from `addresses_select_own_technician` (job/ticket-scoped, via
`20260704120000_technician_customer_address_rls.sql`) — there is no org-wide technician grant.

**Why this mattered:** not a vulnerability by itself (none of this migration's own DDL grants
anything, so there's no new access to mis-scope), but a wrong comment in a verification script
that future readers would trust to explain *why* a role sees what it sees — worth being
accurate, especially in a file whose entire purpose is to be read by a human confirming RLS
behaves as expected after a migration. Doubly worth it here since this review's own first draft
repeated the same stale claim instead of catching it.

**Fix applied:** `supabase/migrations/20261204170000_address_sub_area_field.post_apply_verify.sql`
line 70 rewritten to name only the correct policy for technician access and to explain why the
dropped one no longer applies. Dollar-quote balance (`$verify$` ×2) and literal escaping
re-verified after the edit.

## Finding 2 (confirmed non-issue): row-level RLS covers the new column automatically

`addresses_select_staff` / `addresses_select_own` / `addresses_select_own_technician` /
`addresses_write_sales` / `addresses_write_own` (the policies actually live today —
`addresses_select_technician_search` was dropped by `20260716100000`, see Finding 1's
correction above) are all `using`/`with check` clauses evaluated per **row**, not per column
(`20260701091300_rls.sql`, `20260704120000...`). Postgres RLS has no column-level grant mechanism
being used here — a policy that allows a role to see/write a row allows it to see/write every
column on that row, including a brand-new nullable one this migration adds. There is no way
for `sub_area` specifically to be more or less visible than `door_no`/`landmark`/any other
address column. Confirmed by reading the policy definitions directly, not inferred.

## Finding 3 (confirmed non-issue): injection surface

No parameter, no caller-supplied value, anywhere in this migration or its companion scripts.
Every `||` concatenation in the apply/dryrun/rollback_exercise/post_apply_verify files builds
diagnostic text from values the query itself already typed (uuid/text/int/boolean), never from
unsanitized external input. `capture_live_pins.sql` (new, item 3) is a single parameterless
`select` with no concatenation of any kind.

## Finding 4 (confirmed non-issue): anon exposure

This migration grants nothing to `anon` (no `grant`/`revoke` statement at all). The
rollback-exercise probe's anon-exposure check (sha256 digest of every function `anon` can
`EXECUTE`, before vs after the whole apply+rollback cycle) exists to prove this stays true, not
because anything here is expected to change it.

## Rollback exactness (item 3's second ask)

Confirmed by reading the actual committed function/trigger definitions in this repo, not
guessing: **no function or trigger is created, replaced, or referenced by this migration at
all.** The only existing trigger on `public.addresses`,
`addresses_backfill_null_links` (`20261023110000_backfill_address_links.sql`), fires `after
insert or update of lat, lng` — its column list does not include `sub_area`, so adding or
dropping that column has zero interaction with it. The rollback
(`alter table public.addresses drop column if exists sub_area;`) is therefore an exact,
complete reversal of the one statement this migration performs — there is no function body or
trigger definition to hash-compare because none exists in either direction.

## Overall verdict

No security defects found in the final (renamed) files. One documentation-accuracy finding
(technician role attribution) found and fixed during this pass.
