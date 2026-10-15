# P2: staff profile fields, forced first-login password, per-person colour, huddle solution/solved-by and master alerts

Status: BUILT on `feat/p2-staff-profile-huddle`, NOT applied (migration `20261102100000_p2_staff_profile_and_huddle`). Cut from origin/main.
Source: client list 12-10-2026 items 3 and 7; owner decisions of 2026-10-15.

## Item 7: new staff
Name, email, password, designation, full address and mobile are all required when a master creates staff (dialog and Edge Function).
`profiles` gains `designation` and `address` (master-only to change). The first password is shared in person, so the account is created
with `must_change_password = true`: every route redirects to `/change-password` until the person chooses their own.
Existing staff are not forced (the flag defaults to false and is only set by `admin-create-staff` and `admin-reset-staff-password`).

How the flag is kept honest: a client can never set or clear it. The database records `md5` of the password hash when the flag is
set (`password_marker`), and `complete_forced_password_change()` clears it only when the hash has changed, so the screen cannot be
skipped by calling the function. A master's reset arms it again with a fresh marker. Nothing stores or logs a password.

## Item 3: daily huddle
- Everyone internal already sees the huddle (staff and active technicians); customers do not.
- `meeting_issues.solution_by` and `solved_by` are stamped by the database from the signed-in user (a client cannot forge them) and
  shown on the card: "solution by X", "Solved by Y".
- The master gets an in-app notification when a problem is raised, when a solution is given and when a problem is solved
  (not for their own action).
- Technicians may raise a problem and suggest a solution through two narrow RPCs; they cannot edit, solve or task anything.
  A suggestion is accepted only while the problem is open and has no solution yet. Staff mark the problem solved.

## Per-person colour (used by P3)
`profiles.task_color`: golden-angle hue steps, assigned automatically to every staff member and technician (existing ones backfilled
in creation order), master can change it. No two people in an organisation get the same colour until the hue wraps (hundreds of people).

## Not in P2
Task visibility, work log, colour on the task screens (P3). WhatsApp or SMS delivery of the password: none; it stays hand-delivered.

## Estimate
Built: DB 0.75 day, Edge Functions + tests 0.5, dialog + gate + change-password page 0.5, huddle UI 0.5, tests and wrapper 0.5 = **2.75 days**.
Remaining: rehearsal and fixes 0.25, device pass of the gate on the Capacitor build 0.25.

## Risks
A reset clears nothing the user typed; if the flag write fails after the password was changed the function reports `forcedChange: false`.
A user who closes the app on the change-password screen is returned to it at next login (intended).
