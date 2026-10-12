# Independent review brief (for a reviewer with no prior context)

## 0. What you are looking at
GV Mart is a field-service / sales management web app (React + TypeScript, Supabase: Postgres, PostgREST, GoTrue, Edge Functions on Deno). One live organisation plus throwaway test organisations whose names start with `__TEST_`. Repo root is the parent of `gv-mart/`; every path below is relative to `gv-mart/`.

Roles (`profiles.role`, enum `user_role`): `master` (owner), `operation_admin`, `sales_admin` ("sales person"), `technician`, `customer`. Staff = master, operation_admin, sales_admin. `profiles.is_active` is the on/off flag. Every business table has `org_id`; row-level security (RLS) is the main boundary. The browser holds only the public anon key plus the user's JWT. `service_role` is used only by Edge Functions and by SQL run by the database owner (`postgres`).

Helper functions every policy and RPC uses (all `SECURITY DEFINER`, `search_path = public`): `current_org_id()`, `current_role()`, `current_customer_id()`, `current_technician_id()`, `current_technician_is_active()`, `is_master()`, `is_ops_staff()`, `is_staff()`, `is_sales_staff()`.

Migrations are applied by hand (never `supabase db push`); the applied history is `supabase_migrations.schema_migrations`. Files in `supabase/migrations/` are applied unless noted; `supabase/held/` are written and tested but NOT applied. Rollbacks are in `supabase/rollbacks/`, SQL tests in `supabase/tests/` (each is a single rolled-back transaction ending in `RAISE`; the migration file is concatenated in front of it, see the header of each test). Edge Function tests are vitest files in `supabase/functions/_shared/*.test.ts`.

You can read the live schema only if you are given database access; if not, the migrations above are the source of truth, and `docs/phase0-live-findings-2026-10-12.md` lists what was read from the live catalog.

Out of scope: the WhatsApp bot journeys, reports, inventory, the UI beyond the calls named below.

For every item below: **what it is supposed to guarantee**, then **questions to attack it with**. Please also try anything not listed.

---

## 1. Round-robin lead assignment
**Files:** `supabase/migrations/20261010100000_lead_round_robin.sql` (applied, switch OFF); `supabase/held/20261010120000_lead_distribute_pending.sql` (NOT applied); `supabase/held/lead_distribute_concurrency.test.mjs` (two parallel connections, commits throwaway data); `supabase/tests/lead_round_robin.test.sql`, `supabase/tests/lead_distribute_pending.test.sql`; design `docs/round-robin-lead-assignment.md`. Related earlier migration: `supabase/migrations/20261008130000_lead_assignment.sql` (`assign_lead`, `_trg_lead_assigned_guard`).

**Supposed to guarantee**
- With `settings.auto_assign_leads` OFF nothing changes. With it ON, each new lead (INSERT only) goes to exactly one eligible person (role sales_admin, active, `receives_new_leads`, same organisation), least-recently-assigned first; masters are never auto-assigned.
- No lead is assigned twice or skipped under concurrent inserts (per-organisation advisory lock `lead_rr:<org>`).
- Leads that existed before the switch are never touched; only leads flagged `auto_assign_pending` are distributed by the held migration, oldest first, once.
- A client cannot set `assigned_to` or `auto_assign_pending` directly; internal functions are not callable by clients.
- A failure in the distribution never blocks activating a sales person or switching the setting.

**Attack with**
- Can any authenticated or anon caller, in any organisation, cause a lead to be assigned to someone they choose, or flag/unflag leads? (`leads` INSERT/UPDATE policies, `_trg_lead_assigned_guard`, `_trg_lead_pending_guard`, the `app.lead_assign_ok` session setting: can a client set it? via which function?)
- Cross-organisation: can a person or lead from organisation A be picked for organisation B (`_lead_rr_pick`, `lead_rotation` keyed by `profile_id` only)?
- Races: two inserts at the same instant; an insert racing a profile activation or the switch turning ON; the held distribution racing `assign_lead`. Is the lock taken on every path that reads the rotation? Is there a window where a person deactivated mid-run still receives a lead?
- Fail-open: what happens when nobody is eligible, when `lead_rotation` has no row, when `settings` has no row, when the person list is empty?
- Which functions created by these files are executable by `anon`/`authenticated`/PUBLIC? (check `proacl`, default privileges on this project grant EXECUTE to anon/authenticated on new functions).
- Notifications and `lead_assignments` rows written for a person in another organisation?

## 2. Anon / authenticated revokes
**Files:** `supabase/migrations/20261010130000_revoke_anon_lead_helpers.sql`, `supabase/migrations/20261015120000_revoke_unguarded_write_functions.sql`, `supabase/migrations/20261015140000_anon_hygiene_and_stale_booking_guard.sql`; rollbacks and tests of the same names; report `docs/anon-executable-functions-2026-10-12.md`; live findings `docs/phase0-live-findings-2026-10-12.md`. Internal callers were found by searching `prosrc`; Edge Function callers by searching `supabase/functions`.

**Supposed to guarantee**
- The functions named in each file are no longer executable by PUBLIC, `anon` or `authenticated`; `service_role` and the owner still can. Every legitimate caller (definer functions running as the owner, service-role Edge Functions, `pg_cron`) still works.
- `create_purchase_order` is `SECURITY DEFINER` after `20261015120000`; its own guards (organisation match, `is_ops_staff()`) must still stop everyone else.
- `resolve_stale_bookings` allows only: a customer, an active technician, active staff, or the service role, of the same organisation.

**Attack with**
- Call every function in `public` as `anon` and as a signed-in customer with random arguments: which still run and write? Compare against `docs/anon-executable-functions-2026-10-12.md` (it is not exhaustive; verify it).
- Are there overloads (same name, different arguments) that kept their grant? Functions in other schemas (`extensions`, `auth`, `storage`, `cron`, `supabase_functions`)? Functions created later by migrations after the revoke (this project's default privileges re-grant EXECUTE on new functions)?
- Is any revoked function reachable indirectly through an INVOKER function or a trigger executed as the caller?
- Does converting `create_purchase_order` to definer open anything: arguments used as table/column names, `p_supplier_id` from another organisation, `p_items` with another organisation's item ids, `requested_by`?
- `resolve_stale_bookings`: can a customer or technician use it to touch another organisation's data, or to cause unbounded notifications?

## 3. F-06 / F-07 / F-08 migrations
### F-06 no client-side master grant
**File:** `supabase/migrations/20261011120000_profiles_no_client_master_grant.sql` (+ rollback, `supabase/tests/staff_security_fixes.test.sql`). Existing guard it complements: `guard_profile_privileged_columns` (see `supabase/migrations/20261006130000_close_profile_privilege_escalation.sql`).
**Guarantee:** no write issued as `authenticated`/`anon` can create a profile with `role = 'master'` or change a role to `master`.
**Attack:** INSERT vs UPDATE, `upsert`, `ON CONFLICT`, updating `role` through a view or another table, `profiles_update_own`, `profiles_update_master`, `profiles_update_ops_technician`, `set role`, `SECURITY DEFINER` RPCs that write `profiles` (search all of them), the auth hook / signup path that creates profiles, `link_customer_google_account`.

### F-07 inactive staff have no role
**File:** `supabase/migrations/20261015110000_current_role_active_gate.sql` (+ rollback, `supabase/tests/current_role_active_gate_1_before.sql`, `_2_after.sql`); design and matrix `docs/design-current-role-active-gate.md`.
**Guarantee:** an inactive master/operation_admin/sales_admin gets `current_role()` NULL and every helper returns strictly false; no RLS policy or RPC admits them; helpers never return NULL; an organisation can never be left without an active master (except the documented break-glass); technicians and customers are unchanged.
**Attack:** every policy and function that uses `current_role()`, `is_master()`, `is_ops_staff()`, `is_staff()`, `is_sales_staff()` or `current_org_id()` alone, especially guards of the form `if not helper() then raise` with a NULL; `IS DISTINCT FROM`; `coalesce`; policies keyed only on `org_id = current_org_id()` (an inactive person keeps an organisation id); RPCs that read `profiles.role` directly instead of the helpers; the last-master trigger (`_trg_profiles_last_master`: exemptions for `__TEST_` organisation names and for a deleted organisation, the `app.allow_last_master_change` flag: can a client set it, can a master rename their organisation to `__TEST_...`?); Realtime, Storage policies and signed URLs for an inactive user; already-issued JWTs.

### F-08 WhatsApp outbound gate
**File:** `supabase/migrations/20261015100000_whatsapp_outbound_gate.sql` (+ rollback, `supabase/tests/whatsapp_outbound_gate.test.sql`); Edge side `supabase/functions/_shared/wa-test-mode.ts`, `supabase/functions/_shared/whatsapp.ts` (the block at the top of `sendMessage`), UI `src/app/admin/automation/WaTestModeSwitch.tsx`.
**Guarantee:** no client role can INSERT/UPDATE/DELETE `whatsapp_outbox`; staff queue a message only through `send_staff_whatsapp`, only to a number belonging to a record of their own organisation that they reference; senders are logged; when `settings.wa_test_mode_enabled` is true nothing is sent to a number not in `wa_test_allowed_numbers`, and the attempt is logged; only a master can change those two settings.
**Attack:** see section 4 (`send_staff_whatsapp`). Also: all other writers of `whatsapp_outbox` (list them; which run with elevated rights and take a number from user-influenced data?), the dispatcher (`supabase/functions/_shared/wa-milestone-dispatch-core.ts`) which sends rows regardless of who inserted them, number normalisation differences between the SQL check and `toBareMobile`, a settings read failure in `evaluateTestMode`, other code paths that call the Wasi API without `sendMessage`.

## 4. `send_staff_whatsapp`
**File:** defined in `supabase/migrations/20261015100000_whatsapp_outbound_gate.sql`; caller `create_purchase_order`.
**Guarantee:** `SECURITY DEFINER`, empty `search_path`; refuses unless the caller is active staff whose organisation equals `p_org_id`; accepts only `ref_type` in (`purchase_order`, `service_ticket`, `service_visit`, `invoice`); the referenced record must exist in the caller's organisation and the destination must be one of that record's own numbers (supplier for a PO; customer or member for ticket/visit/invoice); `p_customer_id` must match; writes the sender (`sent_by`) and an audit row with only the last four digits; not executable by anon.
**Attack:** number normalisation and comparison (`right(...,10)`, formats, `<> ALL` with empty/NULL arrays), a supplier or customer whose stored number is attacker-controlled (who can edit `suppliers.whatsapp`, `customers.mobile`, `customer_members.mobile`?), a record in another organisation with the same id space, `p_payload` content (message body control), `p_milestone`/`p_template` abuse, rate/volume (can one staff user queue unlimited messages to a legitimate number?), the `'sent'` status written without any send, how the dispatcher treats the inserted row.

## 5. `admin-create-staff`
**Files:** `supabase/functions/admin-create-staff/index.ts`, `supabase/functions/_shared/staff-auth.ts`, `supabase/functions/_shared/staff-cors.ts`; tests `supabase/functions/_shared/admin-create-staff.handler.test.ts`, `staff-auth.test.ts`; UI `src/app/admin/hr/AddStaffDialog.tsx`, `src/services/hr.ts`. Deployed.
**Guarantee:** only an ACTIVE master (verified by `auth.getUser` and a profile read, never from the request) can create an `operation_admin` or `sales_admin` login in their own organisation; role/organisation/active flag are never taken from the body; typed passwords 10-72 bytes and not on a deny-list, generated passwords 14 characters returned once; a start audit row precedes the action and a separate result row follows (the table is append-only); a failed profile insert rolls the auth user back; CORS answers only origins in the `ALLOWED_ORIGINS` secret; errors are fixed strings.
**Attack:** JWT handling (expired, other project's token, anon key, service key); role escalation through body fields, prototype keys, unicode in names/emails; duplicate/case-variant emails; email enumeration through status codes and timing; rollback failure paths; leaving an auth user without a profile; password and email appearing in logs or audit rows; CORS and preflight behaviour; replay; absence of rate limiting; the `verify_jwt` gateway setting.

## 6. `admin-reset-staff-password`
**Files:** `supabase/functions/admin-reset-staff-password/index.ts`, `supabase/functions/_shared/staff-auth.ts` (`checkStaffTarget`, `validateTypedPassword`, `revokeUserSessions`), `supabase/migrations/20261011100000_revoke_user_sessions.sql`; tests `admin-reset-staff-password.handler.test.ts`. Deployed.
**Guarantee:** only an active master, only for an `operation_admin` or `sales_admin` of their own organisation, never a master (including self); audit pair; on success the target's sessions and refresh tokens are deleted; a generated password is returned once.
**Attack:** target selection (id of another organisation, of a master, of a technician or customer, of a user without profile), TOCTOU between the role check and the update, session revocation completeness (access tokens already issued remain valid until expiry: what can they do? Realtime? Storage?), whether `revoke_user_sessions` is callable by anything but service_role, password handling in logs, response differences that reveal account existence, an inactive or banned master.

## 7. `admin-set-staff-active` (built, NOT applied, NOT deployed)
**Files (branch `feat/admin-set-staff-active`):** `supabase/functions/admin-set-staff-active/index.ts`, `supabase/held/20261015150000_set_sales_person_active.sql` (+ rollback, `supabase/tests/set_sales_person_active.test.sql`), `supabase/functions/_shared/admin-set-staff-active.handler.test.ts`, `src/services/hr.ts`, `src/app/admin/hr/StaffSalaryTab.tsx`; design `docs/design-admin-set-staff-active.md` (decisions at the end).
**Guarantee:** only an active master can deactivate/reactivate a sales person of their own organisation (never a master, never themselves); deactivation cuts data access immediately (database), bans the login, revokes sessions, returns the person's open leads (unassigned, flagged for redistribution), follow-ups and tasks to the acting master, in one transaction, idempotently, with an append-only audit pair; reactivation unbans first then activates and hands nothing back; a client cannot flip a sales person's `is_active` directly; `set_sales_person_active` is callable only by `service_role`.
**Attack:** the RPC re-validation (actor, target, organisation, role) against a forged `p_actor`; partial failures and their order (is there any state in which a deactivated person keeps access, or a reactivated one is half-active?); concurrency with `assign_lead`, with round-robin inserts and with a second deactivation; moving work into the actor's queue (notification spam, ownership of historical rows); the trigger `guard_sales_active_client` (bypass through another column, a view, upsert, a definer RPC); what happens to leads `status in ('won','lost')`, to rows referencing the person with `ON DELETE SET NULL`; the distribution call at the end (`_lead_distribute_pending`, only if present).

## 8. Table privileges for anon (built and tested, NOT applied)
**Files (branch `feat/revoke-anon-table-privileges`):** `supabase/migrations/20261016500000_revoke_anon_table_privileges.sql`, `supabase/rollbacks/20261016500000_revoke_anon_table_privileges.rollback.sql`, `supabase/tests/anon_table_privileges.test.sql`; the previous ACLs of every public relation and every default-ACL row are in `Desktop\GV_mart_acl_backup_2026-10-12_tables_before_anon_revoke.json`.
**Why:** this project's default privileges give the `anon` role every table privilege (SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN) on every table a migration creates: 117 of 126 public relations carry them. Nothing is exposed today only because row-level security is on everywhere and every policy reachable by anon needs an identity (checked by reading rows as `anon` and by reading the policies). That makes RLS the only gate; the migration removes the privilege layer.
**Supposed to guarantee**
- `anon` holds no privilege on any existing public table, view or sequence; a table, view or sequence created later by `postgres` does not inherit one (default privileges changed for `postgres`; for `supabase_admin` they could not be changed from this session and the test reports that as a WARN).
- `authenticated` loses only TRUNCATE, REFERENCES, TRIGGER and MAINTAIN on tables (existing and new); SELECT/INSERT/UPDATE/DELETE and RLS are unchanged.
- Untouched: USAGE on schema `public` for anon, every function's EXECUTE (including the 13 that RLS policies call as the invoking role: `current_role`, `current_org_id`, `current_customer_id`, `current_technician_id`, `current_technician_is_active`, `is_master`, `is_ops_staff`, `is_staff`, `is_sales_staff`, `customer_owns_appointment`, `customer_sees_technician`, `customer_sees_technician_profile`, `is_technician_customer`), `service_role`, `postgres`.
**Attack / check with**
- Is there any request a signed-out client legitimately makes to `/rest/v1/<table>` (public catalogue, branding, login helpers, the mobile shells, the PWA service worker, Edge Functions that call PostgREST with the anon key instead of the service role)? A refusal is now `42501` instead of `[]`.
- Does any `SECURITY INVOKER` function or view executed as `anon` read a table (views owned by `postgres` run as the owner unless `security_invoker`; `v_referral_events` is `security_invoker`)?
- Does anything create tables as a role other than `postgres` (Studio, `supabase_admin`, extensions, the Management API's role)? Those still inherit anon privileges until their default ACL is changed.
- Are there column-level or sequence grants to anon that `REVOKE ALL ON ALL TABLES` does not remove (live check: none, 0 sequences, 0 column ACL rows)?
- Do the persona results in the test really cover the app (customer, technician, sales person, operation admin, master)? It compares 27 operations before and after in one transaction; extend it with the screens you consider critical.
**Report:** `PASS 32 / FAIL 0 / WARN 3` (3 WARN: default ACLs of `supabase_admin`, types S, r, f). Run as a rolled-back transaction on the live database on 2026-10-12.

---

## 9. Cross-cutting questions
1. List every function in schema `public` (and `extensions`, `auth`, `storage`, `cron`) executable by `anon` or `authenticated` that writes data without verifying the caller's identity and organisation.
2. List every table with RLS where an INSERT/UPDATE policy lacks `WITH CHECK`, or a policy depends on a client-controlled column.
3. Any `SECURITY DEFINER` function whose `search_path` can be hijacked, that builds dynamic SQL from arguments, or that trusts a client-supplied organisation id.
4. Any place a session setting (`app.*`) acts as an authorisation flag: can a client reach `set_config` with it (RPC, `SET`, PostgREST headers)?
5. Is `audit_log` really append-only for every role (owner, service_role, authenticated, triggers, cascades from organisation delete)?
6. Anything in these changes that works in a throwaway test organisation but behaves differently in the live organisation (name-based exemptions, seeded settings rows, existing data).
7. Backwards compatibility: which already-deployed client (production web UI before this branch, cached service worker, native shells) calls something whose contract or privileges changed?

## 10. How to report
For each finding: file and line, a concrete reproduction (role, call, arguments, expected vs actual), severity, and a proposed fix. Please separate "confirmed by running it" from "reasoned from the code". Do not run anything against the live organisation's real data; use a throwaway organisation whose name starts with `__TEST_` and remove it with `select purge_test_organisation('<id>')` (owner role only).
