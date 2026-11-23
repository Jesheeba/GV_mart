# Feature: login-activity (HR → Login Activity tab)

**Status 2026-11-23:** LIVE. Migration `20261213100000_login_activity.sql` applied on GO APPLY; DB 30/30, unit 27/27, Playwright E2E 20/20.

## Purpose
Master needs to see when every user (staff, technicians, customers) signed in and out, with date and time, in its own section under HR. There's no source for this today:
- `auth.audit_log_entries` is **empty** on this project (auth audit logging is off). Checked live 2026-11-23.
- `auth.sessions` only holds *open* sessions (49 rows); a row is deleted on sign-out, so history is lost.

## Architecture
**Capture (server-side, no client change):** triggers on `auth.sessions`.
- Every sign-in method (password, Google, OTP, Android app) creates an `auth.sessions` row. Capturing there means one place covers everything and the client can't fake or skip it.
- `AFTER INSERT` → insert `public.login_sessions` row (login time).
- `AFTER UPDATE OF refreshed_at` → set `last_seen_at` (token refresh ≈ "still using the app").
- `AFTER DELETE` → set `ended_at` (sign-out, password-reset eviction via `revoke_user_sessions`, or expiry cleanup).
- Trigger functions: `SECURITY DEFINER`, `search_path=''`, body wrapped in `EXCEPTION WHEN OTHERS THEN RETURN` so **a logging bug can never block a login**.
- Fallback (client RPC from `onAuthStateChange`) **not needed**: rehearsal 2026-11-23 confirmed `postgres` can create triggers on `auth.sessions` (owner `supabase_auth_admin`).

**Data model:** `public.login_sessions`
| column | type | note |
|---|---|---|
| session_id | uuid PK | = auth.sessions.id (dedupes re-fires) |
| user_id | uuid not null | |
| org_id | uuid null | from `profiles` at login; null if profile not created yet |
| role | text null | snapshot at login (role may change later) |
| started_at | timestamptz not null | auth.sessions.created_at |
| last_seen_at | timestamptz null | |
| ended_at | timestamptz null | null = still signed in |
| user_agent | text null | shown as device/browser |

- RLS on, **no** insert/update/delete policies (house style, like `lead_followups`). Select via RPC only.
- Backfill: migration copies the currently open `auth.sessions` rows so the tab isn't empty on day 1 (earlier history doesn't exist anywhere).
- Retention: nightly pg_cron purge of rows with `started_at` older than **90 days**.

**Read:** `list_login_activity(p_from date, p_to date, p_role text, p_search text, p_limit int, p_offset int)` → rows + total_count. `SECURITY DEFINER`, raises unless caller is `master` of the same org; filters by `org_id`. Explicit `revoke ... from public, anon` + `grant ... to authenticated` (watch the default-privileges anon leak).

**UI:** new `LoginActivityTab.tsx` in `src/app/admin/hr/`, 4th tab in `HrPage.tsx`.
- Filters: date range (default last 7 days, IST), role chips (All / Staff / Technicians / Customers), name/phone search.
- Columns: Name, Role, Login date+time, Last active, Logout date+time (or "Signed in" badge), Duration, Device.
- Paginated (avoids the known 1000-row cap). Empty, loading, error states. i18n keys under `hr.loginActivity.*`.
- Service in `src/services/loginActivity.ts`, React Query hook; zod-validated params.

## Decisions (owner, 2026-11-23)
- Show login + logout + last active + duration.
- Device/browser only, **no IP stored** (DPDP: least personal data).
- Retention **90 days**.
- Customers in the same HR tab, behind a role filter.

## Impact map
| Touches | Risk |
|---|---|
| `auth.sessions` triggers | **Highest risk**: an erroring trigger would block every login. Mitigated by exception-swallow + rehearsal test that a failing insert still lets the session commit. GoTrue upgrades could change the table; trigger just stops recording, logins unaffected. |
| `revoke_user_sessions` (password reset) | Its deletes now fire the delete trigger → `ended_at` set. Intended. |
| `profiles` (read only) | Role/org lookup. No change. |
| `HrPage.tsx` | Adds a tab. Salary/Incentives/Rewards untouched. |
| `src/types/database.ts` | Not touched: service uses the existing `rpc(name as never)` cast pattern (same as `services/hr.ts`); row type lives in `services/loginActivity.ts`. |
| i18n files | New keys only. |
| pg_cron | One new nightly purge job (90 days). |
| Router / RequireRole | None. HR already master-only. |

## Edge cases and failure modes
- Customer signs in before a profile exists (auto-onboard): org_id/role null at insert → RPC fills from current `profiles` via join so they still show.
- Same user on two devices → two rows, both shown.
- App closed without sign-out → `ended_at` stays null; "Last active" shows real recency; duration shown as "open". Sessions expire → delete fires → closed.
- Token refresh every ~hour → trigger only touches one row by PK; negligible load.
- Non-master caller (sales_admin, technician, customer, anon) → RPC raises; table select blocked by RLS.
- Cross-org: master sees only own org's rows.
- Bad input: from > to, range > 366 days, limit > 200 → rejected (zod + RPC).
- Times stored UTC, displayed IST.
- Test accounts: shown, with existing test flag if available; not excluded silently.

## Acceptance criteria
1. Signing in by password, Google, or OTP creates exactly one `login_sessions` row with correct user, role, org, start time.
2. Signing out sets `ended_at`; password-reset eviction also sets it.
3. A forced error inside the trigger does not prevent sign-in (rehearsal test).
4. Master sees HR → Login Activity listing staff, technicians and customers with login date/time, last active, logout date/time, duration, device.
5. Role filter, date range, and search work; pagination works past 200 rows.
6. sales_admin / operation_admin / technician / customer / anon cannot read any rows (RPC raises, direct select returns 0).
7. Master of org A never sees org B rows.
8. Existing HR tabs still work; `tsc` clean; full test suite passes.
