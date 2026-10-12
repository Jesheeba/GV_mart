# Design (not built): `admin-set-staff-active`

Status: DESIGN ONLY. Not built, not deployed. It will need its own security review packet. It builds on the reviewed
`_shared/staff-auth.ts` (active-master guard, target check, append-only audit, session revocation, fixed error messages,
`staff-cors.ts`).

## Purpose
Master-only. Deactivate or reactivate a `sales_admin` (first scope: sales persons; operation_admin can be added later). Deactivation must
(1) cut access at once, (2) block login, (3) revoke sessions, (4) return the person's open leads to "unassigned", (5) leave an
immutable record. Reactivation reverses 1-3 and does NOT give leads back.

## Request / response
`POST { profileId, active: boolean, reason?: string }` -> `{ ok, active, leadsUnassigned?, steps: { db, ban, sessions } }`. Fixed error messages; no GoTrue text forwarded.

## The eight steps (order matters)
1. **Guard.** `requireActiveMaster`. Target must be a `sales_admin` of the caller's organisation (reuse `checkStaffTarget` with a role allow-list of `sales_admin`), never the caller, never a master. A request that does not change the state (already inactive/active) is a no-op that still returns the current state (idempotent).
2. **Audit first.** Append-only START row (`STAFF_DEACTIVATE` / `STAFF_REACTIVATE`): actor id and name, target id, reason. No row, no action (fail closed).
3. **One database transaction** through a service-role-only definer RPC `set_sales_person_active(p_profile_id, p_active)` (EXECUTE revoked from PUBLIC/anon/authenticated, empty `search_path`, fully qualified names):
   * re-checks role = `sales_admin`, organisation, not a master;
   * sets `profiles.is_active`;
   * on deactivation, unassigns every OPEN lead (status not won/lost) assigned to that person using the existing `app.lead_assign_ok` mechanism, inserts one `lead_assignments` row per lead (reason `deactivated`), does NOT re-run round robin and does NOT touch follow-ups;
   * returns the number of leads unassigned.
   This step alone cuts all data access through `is_staff()` / `is_sales_staff()` (and, after F-07, `current_role()`), with no waiting for the JWT.
4. **Ban the login.** `admin.auth.admin.updateUserById(id, { ban_duration: '876000h' })` (reactivation: `'none'`). On reactivation the order is reversed: unban first, then set active.
5. **Revoke sessions.** `revokeUserSessions` (F-01 function): refresh tokens and sessions deleted, so refresh fails and `auth.getUser` on the old token fails for Edge Functions. Reactivation does not need this.
6. **Completion row.** Append-only RESULT row with `db`, `ban`, `sessions` outcomes and the lead count, same `correlation_id`. If any of steps 3-5 failed, the response says exactly which, the row says `result: partial`, and the master can simply retry (every step is idempotent).
7. **Reactivation without returning leads.** Unassigned leads stay unassigned; with auto-assign ON the held distribution migration treats the person as newly eligible (only for leads flagged waiting). No old lead is moved back.
8. **Block the side door.** A trigger on `profiles` (SECURITY INVOKER, `current_user in ('authenticated','anon')`) refuses any client-side change of `is_active` on rows whose role is `sales_admin` or `operation_admin`, with the message "use the staff deactivation function". The UI stops calling the direct `profiles.is_active` update for those roles (`setStaffActive` in `services/hr.ts`). Technicians are excluded (they have their own flow) and masters cannot be deactivated from the client at all (F-07 section 5).

## Failure matrix
| Failure | State left | What the master sees | Safe because |
|---|---|---|---|
| Audit start row fails | nothing changed | 500, "nothing was changed" | fail closed |
| Step 3 fails | nothing changed | 500 | single transaction |
| Step 4 fails after step 3 | inactive in DB, login not banned | `partial`, retry | data access already cut |
| Step 5 fails | inactive + banned, old session objects remain | `partial`, retry | refresh refused by ban; data access cut |
| Completion row fails | work done, no result row | success + warning | "no completion row" means outcome unknown, readable from the data |
| Reactivation step 4 fails | still inactive + banned | error | no access granted |

## Residual window
Database access: about zero after step 3 (given the F-07 `current_role()` change for non-sales roles). Until the session is revoked
or the token expires (`jwt_expiry`, 3600 s in `config.toml`, live value unverified): Realtime sockets already open, signed Storage
URLs already issued, and any Edge Function that trusts only `auth.getUser`.

## Test plan (throwaway `__TEST_` organisation, rolled-back SQL plus live REST/Auth steps)
1. 401/403 matrix as for the other staff functions; target master, self, technician, other organisation -> refused.
2. Deactivate a throwaway sales_admin with 3 open and 1 won lead: 3 leads unassigned with `lead_assignments` rows, won lead untouched, follow-ups untouched, nobody else's leads touched.
3. After step 3: the persona's REST calls to leads/customers/RPCs return nothing/403; after step 4 sign-in is refused; after step 5 the old refresh token is refused and `auth.getUser(oldAccessToken)` fails.
4. Fault injection per step (RPC revoked, ban call failing) -> `partial` response, retry converges, audit has start + result rows.
5. Reactivate: login works again, no leads returned, round robin counts them as eligible only for new/waiting leads.
6. Client-side `update profiles set is_active` on a sales_admin is refused for a master and for the person themselves.
7. Idempotency: repeating deactivate/reactivate changes nothing and writes a no-op audit pair.
8. Clean up with `purge_test_organisation` only.

## Decisions I need before building
* Is operation_admin in scope for the first version? (Recommended: sales persons only.)
* Should deactivation also remove the person from `lead_rotation`? (Recommended: no, harmless; eligibility already requires `is_active`.)
* Notification to the deactivated person is impossible (no channel); do you want one to the master on partial failures? (Recommended: yes, in-app.)

---

## Revision 2026-10-12 (design only, after the live catalog read; nothing built)

Facts checked against the live database that the eight steps above depend on:

* `profiles.is_active` today: a master can flip any staff row's `is_active` straight from the client (`setStaffActive` in `src/services/hr.ts`); the only client rule is "nobody changes their own is_active" (`guard_profile_privileged_columns`). Step 8's trigger is therefore a real behaviour change for the HR screen, which must call the Edge Function instead.
* Leads: `leads.assigned_to` is written only under `app.lead_assign_ok = '1'` (see `assign_lead`); `lead_assignments` has `from_user, to_user, assigned_by, reason, created_at` and no CHECK on `reason`, so the reason `'deactivated'` needs no schema change. `assign_lead` itself cannot be reused (it needs a caller role); the RPC does its own `update leads` under the flag.
* **Other places a deactivated person still owns work** (not covered by the first draft): `lead_followups.assigned_to` (post-service follow-ups, item 13), `tasks.assignee_id` (including the recurring PO payment reminders, whose owner is a master), `leads.owner_id`. Decision needed per table: leave, clear to unassigned, or reassign to the master. Recommended: clear `lead_followups.assigned_to` (the existing "unassigned = all sales staff" rule applies), leave `tasks` and `leads.owner_id` untouched and list them in the completion row.
* F-07 is a prerequisite for non-sales roles only; for `sales_admin` the data cut-off in step 3 already works through `is_staff()` / `is_sales_staff()`.
* The F-07 last-master trigger never blocks a sales_admin deactivation; masters are not valid targets.
* `revoke_user_sessions` is live (2026-10-12) and `staff-auth.ts` already calls it after a reset.

Open decisions (unchanged from above, plus one): operation_admin in scope for v1? (recommended: no, sales persons only); remove from `lead_rotation`? (recommended: no, eligibility already needs `is_active`); in-app notification to the master on `partial`? (recommended: yes); **new:** when auto-assign is ON, should the person's unassigned leads be flagged `auto_assign_pending` so the next distribution spreads them, or stay unassigned for the master to hand out? (recommended: stay unassigned, as in the reviewer's step 3).

Test plan additions: a deactivated person's open post-service follow-up is cleared; `tasks` rows are listed, not changed; the HR screen's old direct update is refused with the documented message; a master cannot be deactivated through any path.

---

## Decisions 2026-10-12 (owner) - design only, still not built

Replaces the "recommended" answers above. What happens to a deactivated sales person's work, all inside the single database transaction of step 3 (`set_sales_person_active`, service-role only):

| Their work | Decision | How |
|---|---|---|
| Open leads (`leads.assigned_to`, status not won/lost) | Return to the unassigned pool, flagged **needs reassignment** for the next distribution | `assigned_to = NULL` and `auto_assign_pending = true` under `app.lead_assign_ok = '1'`; one `lead_assignments` row per lead (`from_user` = the person, `to_user` NULL, `assigned_by` = the acting master, reason `deactivated`). Won/lost leads are untouched. |
| Open follow-ups (`lead_followups.assigned_to`, open, includes post-service calls) | Go to the master queue | `assigned_to` set to the acting master; due times and history untouched; a completion-row count. |
| Open tasks (`tasks.assignee_id`, status open) | Reassigned to a master | `assignee_id` = the acting master; `assigned_by` unchanged; recurring-series rows included. Done tasks untouched. |
| `leads.owner_id`, `invoices.sold_by`, history | Untouched | They record who did something, not who owes work. |

Consequences to be aware of (found while reading the distribution migration):
1. **The distribution only runs on two triggers**: a sales person becoming eligible, and `auto_assign_leads` going OFF -> ON. Flagged leads would otherwise wait indefinitely. So step 3 ends with a call to `_lead_distribute_pending(org)` (wrapped in the same exception block that logs a WARNING and swallows, F-12) when the switch is ON: the flagged leads are spread over the remaining eligible people immediately, and the master gets the existing `lead_auto_assign_waiting` notice if nobody is eligible. With the switch OFF they simply stay unassigned + flagged, and the master assigns by hand; a hand-assigned lead keeps the flag until the next distribution run, which only clears the flag on it and does not move it (verified in the distribution function).
2. If NOBODY is eligible (deactivating the last sales person), the flagged leads wait for the next person who becomes eligible: expected, and visible to the master as the waiting notice.
3. Reactivation gives nothing back (as before); the person is simply eligible for new/flagged leads again.
4. Step 3 now writes to four tables instead of one (leads, lead_assignments, lead_followups, tasks) plus a notification; the completion audit row records the four counts. All still one transaction, so a failure leaves nothing half-moved.

Test plan additions: 3 open + 1 won lead, 2 open follow-ups (one post-service), 3 open + 1 done task, one recurring task: afterwards leads unassigned and flagged (won untouched), follow-ups on the master, open tasks on the master, done task untouched, counts in the completion row; with the switch ON and a second eligible person the flagged leads are spread within the same call; with the switch OFF they stay flagged; a lead of someone else is never touched.
