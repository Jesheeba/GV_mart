# Security review: staff-login Edge Functions (and related database changes)

Originally prepared 2026-10-06; updated 2026-10-08 after the independent review. **Nothing here is deployed.** The live
`admin-reset-staff-password` is still the OLD v1 (any master target, no active-caller check, no audit row). Nothing in this
branch is pushed or applied live except where stated.

## 1. Outcome of the independent review

Verdicts given by the reviewer: `admin-create-staff` DEPLOY AFTER FIXES, hardened `admin-reset-staff-password` DEPLOY AFTER
FIXES, anon-revoke migration SAFE (live), round robin SAFE TO KEEP LIVE (switch OFF), held distribution DO NOT APPLY YET.
Limit of the review: it was done from the code; live catalog checks were blocked (Management API token revoked) and the
functions have never run under real Deno against a real Auth server.

| ID | Sev | Finding | Status in this branch |
|---|---|---|---|
| F-01 | Medium | A password reset left the target's existing sessions and refresh tokens valid. | **APPLIED LIVE 2026-10-12** (`migrations/20261011100000_revoke_user_sessions.sql`, rolled-back SQL test green first). (service-role-only definer function, empty search_path) + `revokeUserSessions()` called after a successful reset; failure is reported in the response and audit row. Live refresh-token test still to run (see 5). |
| F-02 / F-05 / F-13 | Medium | Audit rows were written "pending" then UPDATEd; `REVOKE UPDATE` alone would have left every row "pending" forever. | **Built.** `staff-auth.ts` now INSERTs a start row and a separate completion row linked by `correlation_id`; nothing is updated; a missing completion row means "outcome unknown". |
| F-03 | Medium | `audit_log` was mutable by service role / owner and erased by organisation cascade; `actor_id` lost on profile delete. | **APPLIED LIVE 2026-10-12** (design approved; `migrations/20261011110000_audit_log_append_only.sql`): trigger forbids UPDATE/DELETE/TRUNCATE (two narrow exceptions), UPDATE/DELETE/TRUNCATE revoked from anon/authenticated/service_role, `purge_test_organisation()` for throwaway cleanup, actor name snapshotted into `after`. |
| F-04 | Medium | Typed passwords only needed 8 characters. | **Fixed.** 10-72 BYTES, deny-list of common passwords, repeated/sequential strings refused; one policy for create and reset; UI minimum raised to 10 bytes. Generated passwords unchanged. |
| F-06 | Medium | A master (or stolen master token) could PATCH a profile's role to `master` through PostgREST. | **APPLIED LIVE 2026-10-12** (`migrations/20261011120000_profiles_no_client_master_grant.sql`): no authenticated/anon write can set role = master. |
| F-07 | Medium | The `is_active` gate covers only sales_admin; inactive master/operation_admin keep full DB access. | **Design only**: `docs/design-current-role-active-gate.md`. |
| F-08 | Medium | Re-assessed (see 4): `simulate_inbound_whatsapp` rows are NOT dispatched, but staff can queue real outbound messages another way. | **Open, not in scope of this branch.** Proposed fix in 4. |
| F-09 | Low | A technician can insert unlimited leads (rotation skew, notification spam). | Open. |
| F-10 | Low | `app.lead_assign_ok` is a user-settable session setting. | Open (accepted residual). |
| F-11 | Low | No definer function lists `pg_temp` last in `search_path`. | Static scan: 0 definer functions without a search_path. Needs the live schema CREATE check. |
| F-12 | Low | The held distribution trigger could block activating a sales person if the distribution errors. | **Fixed in the held file** (exception block logs a WARNING and swallows). |
| F-14 | Low | CORS `*`. | **Fixed for these two functions**: `_shared/staff-cors.ts` answers only origins listed in the `ALLOWED_ORIGINS` secret; unset = no Allow-Origin header (fails closed). **Set the secret before deploying.** The shared `cors.ts` (other functions) is unchanged. |
| F-15 | Low | The reset returned GoTrue's raw error text. | **Fixed**: fixed messages only; `classifyAuthError`. |

## 2. What the two functions do (unchanged intent)

* **admin-reset-staff-password** - a master sets a new password (typed, or generated and shown once) for an `operation_admin` or `sales_admin` login in their own organisation, then the target's sessions are revoked.
* **admin-create-staff** - a master creates a new `operation_admin` or `sales_admin` login (email is the login, optional phone, optional one-line reason). There is no email/SMS service: the master hands the password over in person.

Both: POST only, `verify_jwt` on (no `config.toml` entry), JWT verified again in code with `auth.getUser`, caller must be an ACTIVE master (profile read server-side by user id), role/org never taken from the request, audit start row before the action (fail closed).

## 3. Tests

* Unit/handler tests (run in Node with a fake Deno runtime and fake client): `staff-auth.test.ts` 33 (was 21), `admin-reset-staff-password.handler.test.ts` 12 (was 10), `admin-create-staff.handler.test.ts` 13 (was 11). Whole suite 293 passed.
* SQL: `supabase/tests/staff_security_fixes.test.sql` (rolled-back; covers F-06, the audit trigger and revokes, the purge route refusing real organisations, F-01 grants). **Run live (rolled back) 2026-10-12: all checks green.**
* Limit that remains: none of this has run under real Deno / real Auth. The first live test is the post-deploy plan below.

## 4. F-08 re-assessment (static reading of the code)

* `wa-milestone-dispatch-core.ts:74-80` sends only rows with `direction='outbound'`, `wa_message_id IS NULL`, `retried_at IS NULL` and `ref_type IN ('service_ticket','service_visit','invoice','purchase_quote_request')`. It does NOT filter on `status`.
* `simulate_inbound_whatsapp` writes through `send_whatsapp_stub` with `ref_type` `whatsapp_outbox` or `automation_flows`, so those rows are never picked up.
* BUT `send_whatsapp_stub` is granted to `authenticated` (migration 20260702170100:40) and `whatsapp_outbox_insert_staff` lets staff insert directly. A staff user (including an active sales_admin) can therefore insert a row with an allowed `ref_type` and any `to_mobile`, and the cron will send it if a template renders. Proposed fix (not built): the insert policy and the stub must require a `ref_id` that exists in the caller's organisation and a `to_mobile` equal to that record's customer mobile, or restrict direct inserts to definer functions.

## 5. Post-deploy test plan (throwaway `__TEST_` users only)

1. anon key / customer token / no header -> 401 or 403 on both functions.
2. sales_admin, operation_admin and an INACTIVE master -> 403.
3. create with role master / technician / customer -> 400; typed password under 10 bytes, over 72 bytes or on the deny-list -> 400; duplicate email -> 409; body with `org_id` / `is_active` -> ignored.
4. create succeeds: one auth user, one profile in the caller's organisation, exactly TWO audit rows (start + completion, same `correlation_id`), the generated password logs in and appears in no audit row or log.
5. CORS: a request with an allowed Origin gets that exact origin back; an unlisted Origin gets no Allow-Origin header; with `ALLOWED_ORIGINS` unset nothing is allowed.
6. reset a sales_admin: old password stops working; **an already-issued refresh token for that user is refused**; `sessions_revoked: true` in the response and the completion row.
7. reset another master and the caller themselves -> 403.
8. After the audit migration: UPDATE / DELETE / TRUNCATE on `audit_log` fail for service_role, authenticated and owner (except the two documented exceptions); deleting a profile that is an audit actor still works (`actor_id` becomes NULL); a real organisation with audit rows cannot be deleted; `purge_test_organisation` refuses a non-`__TEST_` organisation.
9. After the F-06 migration: a master cannot set any profile's role to `master` from the client; the service role can.
10. Clean up through `purge_test_organisation` only.

Deploy commands (when approved, one function at a time): set the secret first, `supabase secrets set ALLOWED_ORIGINS="https://<app domain>,capacitor://localhost" --project-ref fsunrjithwcjtsutsgea`, then `npx supabase functions deploy admin-create-staff --project-ref fsunrjithwcjtsutsgea` and the same for `admin-reset-staff-password`.

## 6. Residual risks accepted knowingly
A stolen master token can still create sales/operations logins and reset their passwords (every action is audited, masters cannot be created from the client after F-06, and there is still no rate limit); an issued access token works at the database until expiry (JWT lifetime, see `docs/design-current-role-active-gate.md`); typed-password policy is a deny-list, not a strength meter; "must change password at first login" is not enforceable server-side yet.

## 7. Corrections to the original packet
* The original packet appendices copied the code; they are removed because the code changed. The files are the source of truth.
* "No function can mint a master" was true only at the function level (F-06).
* "T16: audit rows can be deleted by someone with database access" understated it: the service role could rewrite them too, and an organisation delete cascaded them away.
