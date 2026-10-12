# Go-live checklist: sales persons (Add Staff, hardened reset, lead distribution)

Prepared 2026-10-12 on branch `fix/staff-security-review`. Project ref `fsunrjithwcjtsutsgea`.
**Legend:** `[YOU]` = needs your explicit approval before I run it (real-world effect: deploy, secret, real accounts, merge, switch). `[AUTO]` = read-only check or rolled-back test, I run it without asking. Nothing below runs until you say so.

## Status update (2026-10-12, later)
Done live: ALLOWED_ORIGINS set (Vercel + capacitor://localhost + https://localhost, the two defaults of Capacitor 8 that the app config does not override); both Edge Functions deployed and live-tested (reset 26/26, create 24/24); F-07, F-08, the unguarded-function revoke and the internal-tables read tightening applied. Still to do from this list: 4 (create the real sales persons), 5, 6, the merge/push (waiting for your explicit push). Sections below are kept as written for reference.

## 0. Where things stand (already done, verified live 2026-10-12)
| Item | State |
|---|---|
| F-01 `revoke_user_sessions` (service role only) | LIVE |
| F-03 append-only `audit_log` + `purge_test_organisation()` | LIVE |
| F-06 no client-side `role = master` | LIVE |
| Branch rebased on origin/main, `tsc -b` clean, 335 unit tests pass | done |
| Edge Functions `admin-create-staff`, hardened `admin-reset-staff-password` | **built, NOT deployed** (live reset is still the OLD v1) |
| F-08 WhatsApp outbound gate (`held/20261015100000_...`) | built, tested, NOT applied |
| F-07 current_role() active gate (`held/20261015110000_...`) | built, tested, NOT applied |
| Lead distribution (`held/20261010120000_lead_distribute_pending.sql`) | built, rolled-back test 18/18 green today, NOT applied; rollback file written |
| Round-robin switch `settings.auto_assign_leads` | OFF (live) |

## 1. Before anything: preconditions `[AUTO]`
1. `supabase projects list` shows project `fsunrjithwcjtsutsgea` under the right account (known token/account alternation issue; the PAT in `.env` is the durable fix).
2. Baseline snapshot of the real organisation (counts and hashes; compare after every live step): leads 68, follow-ups 5, stage log 70, activities 11, tickets 7, outbox 68, profiles 6, customers 4. Real usage may legitimately move these; any move must be explainable.
3. The live organisation has exactly **one** active master. Decide whether to add a second master (recovery) before F-07 is applied. Not required for this checklist.

## 2. Secret and function deploys

### 2.1 `[YOU]` Set the CORS allow-list secret
`supabase secrets set ALLOWED_ORIGINS="https://gv-mart.vercel.app" --project-ref fsunrjithwcjtsutsgea`
* Unset = both functions send no Allow-Origin header (fail closed), so set it BEFORE deploying.
* **Decision for you:** the Android/iOS shells under `gv-mart/android` and `ios` use a different origin (`capacitor://localhost` / `https://localhost`). With only the Vercel origin, Add Staff and Reset Password will work in the browser but be blocked by CORS inside the native shell. If the master uses the native app for this, add those origins (comma separated). The decision recorded so far is the Vercel origin only.

### 2.2 `[YOU]` Deploy the hardened `admin-reset-staff-password` first
`npx supabase functions deploy admin-reset-staff-password --project-ref fsunrjithwcjtsutsgea`
Why first: it replaces the live v1, which lets a master target another master and writes no audit row. It depends on `revoke_user_sessions` and the append-only audit table, both live.
Stop and roll back (redeploy the previous bundle from git) if the checks in 3 fail.

### 2.3 `[YOU]` Deploy `admin-create-staff`
`npx supabase functions deploy admin-create-staff --project-ref fsunrjithwcjtsutsgea`

Both functions have `verify_jwt` on (no `config.toml` entry). One function at a time; `git diff` the function directory against the deployed bundle first (never `supabase functions download` over the working tree: it once clobbered a file with a stale snapshot).

## 3. Post-deploy test plan `[AUTO]` after each deploy (throwaway `__TEST_` organisation and users only)
Test-data rule: the only real-organisation record any test may touch is the flagged "jeshee test trigger" customer. Everything else is a throwaway `__TEST_` organisation, cleaned up ONLY through `purge_test_organisation(<id>)` (owner role; refuses non-`__TEST_` organisations).
Fixture: a `__TEST_` organisation with an active master (real GoTrue login, token columns `''`), a sales_admin, an operation_admin, an inactive master in a second throwaway org.

| # | Check | Pass |
|---|---|---|
| 1 | anon key / customer token / no header on both functions | 401 or 403 |
| 2 | sales_admin, operation_admin, an INACTIVE master | 403 |
| 3 | create with role master / technician / customer; typed password < 10 bytes, > 72 bytes, deny-list; duplicate email; body with `org_id` / `is_active` | 400 / 400 / 409 / fields ignored |
| 4 | create succeeds | one auth user, one profile in the caller's organisation, exactly TWO audit rows (start + completion, same `correlation_id`), the generated password logs in and appears in no audit row or log |
| 5 | CORS: `Origin: https://gv-mart.vercel.app` | that exact origin echoed |
| 5b | CORS: any other origin | no Allow-Origin header |
| 6 | reset a sales_admin | old password stops working; **an already-issued refresh token for that user is refused**; `sessions_revoked: true` in response and completion row |
| 7 | reset another master; reset self | 403 |
| 8 | audit table | UPDATE/DELETE/TRUNCATE refused for service_role, authenticated, owner; deleting an actor profile keeps its audit rows with `actor_id` NULL |
| 9 | F-06 | a master cannot set any profile's role to `master` from the client; the service role can |
| 10 | cleanup | `purge_test_organisation` removes the throwaway organisations; leftovers = 0 |
Failure of 4, 6 or 8 = stop, do not create real accounts.

## 4. `[YOU]` Create the sales persons through Add Staff
Needs from you: for each person full name, login email, optional phone, and who types the password (typed >= 10 characters, or generated and shown once).
1. Sign in as the real master, Staff Salary > Add staff, role **Sales person**. Hand the password over in person (no email/SMS channel).
2. After each creation confirm: person appears active; **Receives new leads** is ON (Staff Salary toggle, master only); exactly two audit rows exist for the creation.
3. Have each person sign in once on their own device: they land on Leads / Daily Follow Up, see no other roles' screens, and see no lead assigned to anyone else (all existing leads are unassigned or the master's, so their list should be "Mine + unassigned").
4. Do NOT create test leads on the real organisation except against the flagged "jeshee test trigger" customer.

## 5. `[YOU]` Apply the distribution migration
`supabase/held/20261010120000_lead_distribute_pending.sql` (moved to `migrations/` and registered in `schema_migrations` by hand, never `db push`; rollback file in `supabase/rollbacks/`).
* With the switch OFF it changes nothing visible: it only adds the function and two triggers.
* Before: baseline from 1.2. After: baseline unchanged, plus `select count(*) from leads where auto_assign_pending` = 0.

## 6. `[YOU]` Switch round robin ON
Masters > Settings > Auto-assign leads (master only; or `update settings set auto_assign_leads = true where org_id = ...`).
Immediately after, `[AUTO]`:
1. Create ONE lead for the flagged "jeshee test trigger" customer from the New Lead form.
2. Expect: the lead is assigned to one of the new sales persons, one `lead_assignments` row (reason `auto round-robin`), one `lead_assigned` notification to that person, `lead_rotation` row updated.
3. Create a second one: it goes to the OTHER person (rotation).
4. Existing 68 leads untouched (hashes from 1.2), no `auto_assign_pending` flags.
5. Remove the two test leads through the normal delete (master); audit rows stay (append-only, expected).
Abort/rollback: switch OFF (UI or SQL); distribution rollback file removes the triggers. Leads already auto-assigned stay with their person; the master can reassign by hand.

## 7. Items that need your decision before or alongside
| Item | Why | My recommendation |
|---|---|---|
| Merge `fix/staff-security-review` to main and push (triggers a Vercel build) | Add Staff UI and the new Automation test-mode dialog live on this branch | Merge only AFTER 2.2 and 2.3 are deployed (the dialog calls the functions) and after the F-08 migration is applied (the test-mode dialog writes two new `settings` columns that do not exist live yet; until then it would fail on save). If you want the Add Staff UI sooner, I can split the F-08 UI into its own commit. |
| Apply F-08 (WhatsApp outbound gate) | Staff can still queue a message to any number | Apply before turning real sales staff loose; then turn the test-mode allow-list ON with only your own number while testing |
| Apply F-07 (inactive staff have no role) | An inactive master/operation_admin keeps full access | Apply in a quiet period, after the sales persons exist and are verified |
| Auth dashboard settings (user action, outside the database) | read live: `site_url` is `http://localhost:3000`, `disable_signup` is false, `password_min_length` is 6, `jwt_exp` 3600 | set `site_url` to the real app URL, disable open signups if customers are only created by staff/Google, raise minimum password length to 10, consider `jwt_exp` 1800 |
| Meeting notes visible to customers/technicians | `meeting_logs`, `meeting_issues`, `automation_flows` are readable by any member of the organisation | tighten the four SELECT policies to staff (small separate migration, needs your OK) |
| ~10 anon-executable write functions with no guard (`run_rental_billing`, `_create_po_from_winning_quote`, ...) | callable with the public anon key plus an organisation id | revoke from PUBLIC/anon/authenticated; their real callers are definer functions and service-role Edge Functions (verified by search) |

## 8. Order at a glance
1 preconditions `[AUTO]` -> 2.1 secret `[YOU]` -> 2.2 deploy reset `[YOU]` -> 3 tests `[AUTO]` -> 2.3 deploy create `[YOU]` -> 3 tests `[AUTO]` -> (F-08 apply `[YOU]`) -> merge/push `[YOU]` -> 4 create sales persons `[YOU]` -> 5 distribution migration `[YOU]` -> 6 switch ON `[YOU]` -> 6 live verification `[AUTO]` -> (F-07 apply `[YOU]`, later).
