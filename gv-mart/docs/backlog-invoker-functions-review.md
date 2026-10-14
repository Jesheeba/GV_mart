# Backlog: review of SECURITY INVOKER application RPCs with no or RLS-only caller guard

Specification only. Nothing here is fixed. Recorded 2026-10-14. Found during the grants audit
(`supabase/migrations/20261024100000_close_public_and_anon_function_execute.sql`), kept separate on purpose: closing anon and
PUBLIC EXECUTE (that migration) does not change what a signed-in user can do through these functions.

## What the finding is

These functions are called as application RPCs by signed-in users. They are `SECURITY INVOKER`, so they run with the caller's own
privileges. Whatever they can do is whatever table privileges and RLS policies allow that caller; the function body adds little or no
check of its own. That is not automatically a hole, but it means their safety depends on RLS and table grants being exactly right,
and a later change to either silently changes what these functions allow.

| Function | Guard in body (static read, 2026-10-14) | Notes |
|---|---|---|
| `set_primary_member` | none | changes which family member is primary on a customer |
| `create_quotation` | none | inserts a quotation; relies on RLS insert policy |
| `award_referral_points` | references `is_*` / `current_*` helpers | writes referral points; points have monetary meaning |
| `create_bill_entry` | references `is_*` / `current_*` helpers | writes an expense / bill row |
| `create_spare_handover` | references `is_*` / `current_*` helpers | stock moves between warehouse and technician |
| `admin_sign_spare_handover` | references `is_*` / `current_*` helpers | admin signature on a handover |
| `confirm_spare_handover` | references `current_*` helpers | technician confirmation |
| `create_spare_return` | references `is_*` / `current_*` helpers | stock return |

## What to check for each (read-only first)

1. The exact table privileges (`GRANT`) and RLS policies that apply to the tables it writes, for each role that can call it:
   customer, technician, sales_admin, operation_admin, master. State what each role can actually do through the function.
2. Whether any id argument can name a row in another organisation, and whether RLS (not the function) is the only thing stopping that.
3. Whether the in-body `is_*` / `current_*` references are a real caller check (they decide whether to raise) or only used to
   fill in values.
4. Whether the function should become `SECURITY DEFINER` with an explicit role check and org filter, like the sale and AMC
   functions, or stay invoker and have the expected RLS asserted by a test.

## Output wanted

A table per function: caller roles that can use it today, what they can change, what they should be able to change, and the
proposed fix (add a guard, convert to definer with checks, or add a regression test that pins the RLS it depends on). Fixes are
separate migrations, each with its own review.

## Not in scope here

The grants migration. It only removes PUBLIC and anon EXECUTE and keeps `authenticated`, so these functions behave the same for
signed-in users after it is applied.
