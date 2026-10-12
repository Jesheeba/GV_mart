# Design (not applied): F-07, one choke point for "inactive staff have no role"

Status: DESIGN ONLY. Nothing here is applied, built or pushed. Needs approval and live verification (the Management API token
was revoked when this was written, so every "live" item below is a query to run, not a result).

## 1. The problem
`is_staff()` / `is_sales_staff()` now require `is_active` for `sales_admin` (live since 2026-10-07). `is_master()` and
`is_ops_staff()` still derive from `current_role()`, which ignores `is_active`. So a deactivated master or operation_admin
keeps full database power, and RPCs that test `current_role()` directly are not covered for sales_admin either.

## 2. Proposed change (single function)
```sql
create or replace function public.current_role()
returns public.user_role
language sql stable security definer set search_path = public
as $$
  select case
           when role in ('master', 'operation_admin', 'sales_admin') and not is_active then null
           else role
         end
    from public.profiles
   where id = auth.uid()
$$;
```
* Same attributes as today (definer, stable, `search_path=public`); `CREATE OR REPLACE` keeps the ACL.
* Technicians and customers are deliberately NOT touched: technicians are gated by `technicians.is_active`
  (`current_technician_is_active()`), and a customer profile's `is_active` has a different meaning (the demo customer is inactive).
* `current_org_id()` is unchanged (an inactive person still has an organisation); see 4.2.
* Rollback (`supabase/rollbacks/<ts>_current_role_active_gate.rollback.sql`, to be written with the migration) restores the exact old body: `select role from public.profiles where id = auth.uid()`.

## 3. Role x is_active matrix (rolled-back live test, throwaway `__TEST_` organisation)
| Persona | is_active | `current_role()` before | after | `is_master` | `is_ops_staff` | `is_staff` | `is_sales_staff` |
|---|---|---|---|---|---|---|---|
| master | true | master | master | true | true | true | true |
| master | false | master | **NULL** | **false** | **false** | **false** | **false** |
| operation_admin | true | operation_admin | operation_admin | false | true | true | false |
| operation_admin | false | operation_admin | **NULL** | false | **false** | **false** | false |
| sales_admin | true | sales_admin | sales_admin | false | false | true | true |
| sales_admin | false | sales_admin | **NULL** | false | false | **false** | **false** |
| technician | true / false | technician | technician (unchanged) | false | false | false | false |
| customer | true / false | customer | customer (unchanged) | false | false | false | false |
| signed in, no profile | n/a | NULL | NULL | false | false | false | false |
| anon | n/a | NULL | NULL | false | false | false | false |

Also assert, per persona, the same screen/RPC matrix as `supabase/tests/staff_helpers_smoke.test.sql` (Leads, My Day,
Customers, Invoices, Quotations, Appointments, Service tickets, Settings), plus `assign_lead`, `followup_counts`,
`list_followups`, `create_sale` and `sell_amc_plan`: only the three inactive staff rows may change (to no rows / refused).
Run it before and after and diff, as was done for the sales_admin change.

## 4. Everything that could be affected
### 4.1 Direct callers of `current_role()` (static scan of `supabase/migrations`; live `pg_depend`/`pg_proc` query still to run)
* Functions: `is_master`, `is_ops_staff` (both therefore every policy that uses them), `_lead_resolve_scope`, `assign_lead`, `followup_counts`, `_lead_set_followup_allowed`.
* Policies calling it directly: the notifications role-addressed SELECT (`role = public.current_role()`, `20260701091300_rls.sql:493`) and `settings_select_org` (`current_role() IS DISTINCT FROM 'customer'`, `20261006130000...sql:106`).
### 4.2 Two places that must change in the same migration
* `settings_select_org`: with a NULL role, `NULL IS DISTINCT FROM 'customer'` is TRUE, so an inactive staff member would still read internal settings (their `org_id` still matches). Change it to `current_role() IS NOT NULL AND current_role() <> 'customer'` (or `is_staff()`).
* Any policy that relies ONLY on `org_id = current_org_id()` with no role helper would still admit an inactive person. Live query to find them: policies whose `qual`/`with_check` mention `current_org_id()` but none of `is_master`, `is_ops_staff`, `is_staff`, `is_sales_staff`, `current_role`, `current_customer_id`, `current_technician_id`. Each hit is decided individually.
### 4.3 Runtime effects
* A deactivated person who still has a session gets empty lists and refused RPCs immediately (no waiting for the JWT to expire).
* `useProfile` reads the user's own `profiles` row through `profiles_select_own` (`id = auth.uid()`), which does not use `current_role()`, so an inactive user still loads their own profile; the route guards then see an unusable role. A "your account is inactive" screen is a UI follow-up.
* The held distribution migration is unaffected (it reads `profiles.is_active` directly).
* The demo operation_admin and sales_admin are already inactive AND banned: no behaviour change.

## 5. Protecting the master from locking themselves out
1. **Never leave an organisation with no active master.** A `BEFORE UPDATE OF is_active, role OR DELETE` trigger on `profiles`
   raises when the change would deactivate, demote or delete the last ACTIVE master of that organisation, for every caller
   including the service role. Break-glass for a DBA only: `set local app.allow_last_master_change = '1'` AND `current_user = 'postgres'`.
2. Clients already cannot change their own `is_active` (existing guard). `checkStaffTarget` already refuses master targets in the Edge Functions.
3. **Recovery path (documented, tested once on a throwaway):** with owner access (Supabase SQL editor, which bypasses RLS):
   `update public.profiles set is_active = true where id = '<master id>';` then, if the login was banned,
   `update auth.users set banned_until = null where id = '<master id>';` (or Dashboard > Authentication > Users > Unban). The
   service-role key and the dashboard are the root of trust; keep two people with dashboard access.
4. The F-06 migration (no client-side `role = master`) plus step 1 together mean the only way to remove the last master is deliberate DBA action.
5. Rollout order to avoid a self-inflicted outage: (a) apply the last-master trigger; (b) verify at least two active masters, or accept one and test recovery; (c) apply the `current_role()` change in a quiet period; (d) run the matrix live; (e) keep the rollback file ready.

## 6. JWT window after the change
A stolen or already-issued access token still passes signature/expiry checks, but every RLS policy and RPC now returns nothing
for an inactive staff profile, so the residual window for database access is about zero. What remains until the token expires
or the session is revoked: Realtime sockets already subscribed, signed Storage URLs already issued, and Edge Functions that only
call `auth.getUser` without reading the profile. `supabase/config.toml` says `jwt_expiry = 3600` with refresh-token rotation on;
**the live project value is unverified** (dashboard setting): confirm it, and consider 900-1800 seconds.

---

## 7. Revision 2026-10-12 (live catalog read, migration built and tested - NOT applied)
Built as `supabase/held/20261015110000_current_role_active_gate.sql` (rollback in `supabase/rollbacks/`), tests
`supabase/tests/current_role_active_gate_1_before.sql` + `..._2_after.sql` (run as one rolled-back transaction: matrix before, migration, matrix after).

### 7.1 What the live catalog changed in the design above
1. **`is_staff()` and `is_sales_staff()` do not call `current_role()`.** They read `profiles` directly. Section 2 alone would have left an inactive master / operation_admin with `is_staff()` = true. Both are rewritten (every office role must be `is_active`).
2. **Fail-open guards.** `is_master()` and `is_ops_staff()` return NULL for a NULL role, and about 40 functions guard with `if not public.is_master() then raise ...` or `if not (is_ops_staff() or is_sales_staff()) then raise ...`. NULL makes the IF skip: the guard passes. Changing `current_role()` first would have opened them to every inactive staff member. The helpers are now `coalesce(..., false)` in the same migration (this also closes the same hole for a signed-in user with no profile, which exists today).
3. **`settings_select_org`** used `IS DISTINCT FROM 'customer'` (the only policy with that pattern): fixed to `current_role() IS NOT NULL AND <> 'customer'`.
4. **Last-master protection** is a `BEFORE UPDATE OF is_active, role, org_id OR DELETE` trigger. Exemptions: organisation already gone (cascade), `__TEST_` organisations (so throwaway cleanup keeps working), and DBA break-glass (`postgres` + `set local app.allow_last_master_change = '1'`).

### 7.2 Every place that changes if `current_role()` returns NULL
Functions that call it directly: `is_master`, `is_ops_staff` (rewritten); `_lead_resolve_scope`, `_lead_set_followup_allowed`, `assign_lead`, `followup_counts` (all reached only after an `is_sales_staff()` gate, which is boolean and now requires active; `_lead_set_followup_allowed` has `else false`; tested in the matrix: refused at the guard). Policies that call it directly: `notifications_select_own_role` and `notifications_update_own_role` (`role = current_role()` is NULL, no match, and `is_master()` is now false: nothing visible), `settings_select_org` (fixed). The 34 org-only SELECT policies (catalogues etc.) do not use a role helper and are unchanged: an inactive person reads them exactly like a customer does.
Separately found (not part of this migration, needs a decision): `meeting_logs`, `meeting_issues`, `automation_flows`, `payment_settings` are in that org-only group, so any customer or technician of the organisation can read internal meeting notes and automation rows.

### 7.3 Matrix result (live functions before, migration, after; throwaway `__TEST_` organisation)
* Active master / operation_admin / sales_admin / technician / customer: every helper, every visible row count and every RPC result **identical** before and after.
* Inactive master, before -> after: `current_role` master -> NULL, all four helpers true -> false, every table count (leads, customers, invoices, tickets, settings, audit_log, purchase orders, suppliers, notifications) 1 -> 0 (profiles 8 -> 1, own row), and RPCs that **succeeded before** (`assign_lead`, `delete_lead`, `mark_po_paid`, `refresh_amc_statuses`, `followup_counts`, `list_followups`) now refused at the guard (`create_sale`, `delete_customer`, `compute_salary`, `sell_amc_plan`, `set_item_standard_time` refused by the guard instead of a later validation).
* Inactive operation_admin: same, for the ops-guarded functions and ops-visible tables. Inactive sales_admin: only `current_role` and `settings` change (already gated by the sales helpers since 2026-10-07).
* Signed in, no profile: helpers NULL -> false; the guards that used to fall through (`delete_lead`, `mark_po_paid`, `compute_salary`, `refresh_amc_statuses`, `set_item_standard_time`, `sell_amc_plan`, `delete_customer`) now refuse at the guard.
* Last-master tests: owner cannot deactivate, demote, move or delete the only active master; a master cannot deactivate themselves; the break-glass flag does nothing for a client session; with two active masters the first can go and the second is protected; re-activation (recovery) works; `postgres` + flag works; `__TEST_` organisations exempt.

### 7.4 Rollout and rollback
1. Confirm the live organisation has at least one ACTIVE master (it has exactly one today: report it to the owner; consider a second master for recovery).
2. Apply the migration (one transaction), then run the matrix live read-only for the same personas and diff against the table above.
3. The UI shows empty lists for a deactivated person; a "your account is inactive" screen is a follow-up.
4. Rollback file restores the exact 2026-10-12 bodies. Recovery for a locked-out organisation: owner SQL `update public.profiles set is_active = true where id = '<master id>';` then, if banned, `update auth.users set banned_until = null where id = '<master id>';`.
5. Residual: `jwt_exp` is 3600 s (read live). Database access of an inactive person is cut immediately; what remains until the token expires or `revoke_user_sessions` runs: Realtime sockets already subscribed, signed Storage URLs already issued, and Edge Functions that trust only `auth.getUser`.
