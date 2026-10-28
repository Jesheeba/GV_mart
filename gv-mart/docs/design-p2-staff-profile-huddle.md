# P2: staff profile fields, forced first-login password, per-person colour, huddle solution/solved-by and master alerts

Status: BUILT on `feat/p2-staff-profile-huddle`, NOT applied (migration `20261102100000_p2_staff_profile_and_huddle`). Cut from origin/main.
Source: client list 12-10-2026 items 3 and 7; owner decisions of 2026-10-15.

## Item 7: new staff
Name, email, password, designation, full address and mobile are all required when a master creates staff. The Edge Function rejects
a request without a mobile, a designation or a full address (400, nothing written); the dialog is only the first line.
`profiles` gains `designation` (master-only to change). The first password is shared in person, so the account is created with
`must_change_password = true`: every route redirects to `/change-password` until the person chooses their own.
Existing staff are not forced (the flag defaults to false and is only set by `admin-create-staff` and `admin-reset-staff-password`).

### Who can read an address (verified on origin/main 0101955, repo policies; the live database was not queried)
Were it on `profiles`: `profiles_select_own` (the person), `profiles_select_staff` (master, operation_admin AND sales_admin of the
organisation, every column) and `profiles_select_by_customer` (a customer sees the whole profile row of a technician on their
appointment). That is why the address is NOT on `profiles`. It is in `staff_private`, readable only by the person themselves, the
master and operation_admin of the organisation; writable by the master (and the service role). Technicians, sales_admin and
customers read nothing. There is no audit trigger on it (it would copy the address into `audit_log`, which every staff role reads).
Phone already sits on `profiles` (existing) and is readable by the same three policies.

### How the forced change is kept honest
A client can never set or clear the flag. The marker (an md5 of the password hash when the flag was armed) lives in
`profile_password_markers`: RLS on, no policy, no privilege for any API role, touched only by three SECURITY DEFINER functions with an
empty search_path and schema-qualified `auth.users`. `complete_forced_password_change()` clears the flag only when the current hash
differs from the marker. Order is enforced in the Edge Functions and tested: password FIRST, flag SECOND (`arm_forced_password_change`,
service role only). Re-entering the SAME password: GoTrue itself refuses a new password equal to the current one (error
`same_password`); and if it were ever accepted, bcrypt salts every hash, so the stored hash still changes and the check passes. The
same-password refusal is GoTrue behaviour and is to be confirmed on the live project; the salt argument does not depend on it.
Nothing stores or logs a password.

## Item 3: daily huddle
- Everyone internal already sees the huddle (staff and active technicians); customers do not.
- `meeting_issues.solution_by` and `solved_by` are stamped by the database from the signed-in user (a client cannot forge them) and
  shown on the card: "solution by X", "Solved by Y".
- The master gets an in-app notification when a problem is raised, when a solution is given and when a problem is solved
  (not for their own action).
- Technicians may raise a problem (at most 10 a day each; staff unlimited) and suggest a solution through two narrow RPCs; they
  cannot edit, SOLVE or task anything. A suggestion is accepted only while the problem is open and has no solution yet. Only staff
  mark a problem solved (the update policy is staff-only; a test asserts a technician's attempt changes nothing).
- Huddle reminder interaction: a problem needs today's `meeting_logs` row, so `raise_huddle_issue` creates one with `recorded_by`
  NULL and no notes. `wa_send_huddle_reminder` used to treat ANY log as "huddle held", so a technician raising a problem at 9 a.m.
  would have silenced the reminder. It now counts a log only when staff recorded it (`recorded_by` set) or it carries notes. Same
  signature and grants; the rollback restores the old function.

## Per-person colour (used by P3)
`profiles.task_color`: golden-angle hue steps, assigned automatically to every staff member and technician (existing ones backfilled
in creation order), master can change it. No two people in an organisation get the same colour until the hue wraps (hundreds of people).

## Not in P2
Task visibility, work log, colour on the task screens (P3). WhatsApp or SMS delivery of the password: none; it stays hand-delivered.

## Deploy order (mandatory)
1. the migration `20261102100000` (and only after the rehearsal is clean);
2. the Edge Functions `admin-create-staff` and `admin-reset-staff-password` (they call `arm_forced_password_change` and write
   `staff_private`, which exist only after step 1);
3. the front end.
The front end must never reach main before the migration is applied. Safety net, not the plan: the gate reads the flag in its own
query; if that query errors (for example the column does not exist yet) `RequireRole` logs the error and treats the flag as false,
so nobody is locked out.

## Estimate
Built: DB 0.75 day, Edge Functions + tests 0.5, dialog + gate + change-password page 0.5, huddle UI 0.5, tests and wrapper 0.5 = **2.75 days**.
Remaining **0.5 day** = 0.25 rehearsal run and fixes from its output (the rehearsal itself has not been run) + 0.25 device pass of the
first-login gate and the technician Huddle screen on the Capacitor build, which cannot be done from this machine.

## Rollback
After go-live the rollback is unusable, because it refuses while any designation, forced-change flag, `staff_private` row,
`solution_by` or `solved_by` value exists. A forward fix migration is the only way back.

## Names stamped by the database (v3)
`raised_by`, `solution_by` and `solved_by` are what the database observed, on insert as well as update: a client's own values are
ignored. `solution_by` is stamped only when a solution goes from blank to non-blank; editing an existing solution keeps the original
name. A staff member recording the huddle takes over a log a technician created (`recorded_by` NULL -> themselves), so the reminder
stops firing. If the forced-change flag is on and no marker row exists, `complete_forced_password_change` refuses ("ask your
administrator to reset your password") and does not clear the flag.

## Risks
A reset clears nothing the user typed; if the flag write fails after the password was changed the function reports `forcedChange: false`.
A user who closes the app on the change-password screen is returned to it at next login (intended).
