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
