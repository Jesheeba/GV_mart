# Feature: Technician leave request in advance (KPI-protected)

Owner: GV Mart. Priority: URGENT. Build end to end as one feature, on one branch: `feat/technician-leave-request`.
Migration version: `20261106100000`.

## 0. How to work (read first)

1. **Plan before coding.** Read the code first, then post a plan in the chat (files to touch, tables, screens, tests, risks). Wait for the owner's "go" on the plan only if you find a conflict with section 8 (open decisions). Otherwise start building straight after posting the plan.
2. **Reuse what exists.** A technician leave record already exists (the AMC release-path migration `20261025100000` has a trigger `zz_amc_release_on_leave` that reacts to it). Find that table and extend it. Do not create a second leave system.
3. **No database writes by you.** Never run anything against the live database. Write the migration, rollback, tests and the rehearsal wrapper; type them in full in the chat. The owner applies nothing until the reviewer (Claude in the review window) issues a typed `GO APPLY` quoting the commit and the sha256.
4. **No push to `main`.** Push only the feature branch. The owner pushes `main`.
5. **Never print** API keys, tokens, passwords, full phone numbers or WhatsApp message ids. The only test phone is the number ending 6740; never write the full number.
6. **No WhatsApp sends of any kind** from this feature. In-app notifications only.

## 1. The requirement (client)

A technician can submit a leave request in advance from the technician app. If leave is taken this way (requested in advance and approved), the technician's KPI score is not damaged.

## 2. Behaviour

### 2.1 Technician app (Capacitor + web)
- New screen **Request leave**: start date, end date, optional reason (max 500 chars).
- Validation (also enforced in the database, not only the screen):
  - start date is at least `settings.leave_notice_days` days after today (IST). New setting, integer, default `1`.
  - end date is not before start date; maximum length of one request: 30 days.
  - no overlap with the technician's own pending or approved requests.
- **My leave** list: own requests only, with status: pending, approved, rejected, cancelled, revoked. Show the decision note when rejected or revoked.
- The technician can **cancel** their own request while it is pending, or approved and not yet started. Nothing else.
- The list updates right after a decision (in-app notification plus refreshed status; no manual refresh).

### 2.2 Admin app (master and operation_admin)
- New page **Leave requests** (under HR or Technicians, wherever staff leave is managed today).
- Filters: Pending, Approved, Rejected/Revoked/Cancelled. Each row: technician, dates, number of days, reason, requested-at, and a badge: **In advance** or **Late (KPI not protected)**.
- Buttons: **Approve**; **Reject** (asks for a short note); on an approved request that has not started, **Revoke** (asks for a short note).
- On approval, show a warning that lists the technician's already assigned visits on those days so ops can reassign them. Do not auto-reassign.
- Nav entry with a **pending count badge**. The in-app notification to ops links directly to the request.
- Master and operation_admin may also create leave directly for a technician as today; that existing path keeps working and is not "in advance" unless it satisfies the same notice rule by its own created-at (state your decision).

### 2.3 KPI rule
- A day counts as **protected leave** only if the request is **approved** AND was **requested at least `leave_notice_days` days before the leave start** (compare the request's database-stamped `created_at` with the start date; never trust a client flag).
- Protected leave days are **excluded from the technician's expected working days**, so no attendance, availability or completion penalty applies for them.
- Leave that is rejected, cancelled, revoked, unapproved, or late is treated exactly as today.
- Revoking a protected request puts the days back into the KPI.
- Find where the technician KPI score and the Technicians performance table compute attendance/expected days, and apply the exclusion there (one shared SQL function if several places need it). Show on the technician table that days were excluded because of approved leave, so the number is explainable.
- Do not change `compute_incentives` except through the excluded days. `settings.review_incentives_enabled` stays false. No new review-based logic.

### 2.4 Notifications (in-app only)
- New request: to every active master and operation_admin.
- Approved, rejected or revoked: to the technician.
- No WhatsApp, SMS or email.

### 2.5 AMC and visits
- Approved leave triggers the existing release-path behaviour (frees unassigned AMC visits) if that migration is applied. State in the design note whether `20261025100000` is applied and what happens if it is not.
- Visits already assigned to the technician on leave days are never changed automatically.

## 3. Security and data rules

- **RLS:** a technician reads and inserts only their own requests, and may only change status to `cancelled` on their own pending (or approved, not yet started) request. They can never set approved, rejected or revoked, never edit dates after submission, and never see anyone else's request. Master and operation_admin of the same organisation read all; only they approve, reject, revoke.
- **Database stamps:** `created_at`, requested-by, status changes, approver and decision time are stamped by the database from `auth.uid()`; a client cannot choose them.
- **Triggers:** any trigger that must recognise a client must be `SECURITY INVOKER`. Never test `current_user` or `session_user` inside a `SECURITY DEFINER` function (it is always the owner there).
- **Functions:** every new function gets an explicit `revoke ... from public, anon, authenticated`, then only the grants needed. Fixed `search_path` on every definer function.
- **Audit:** no secrets are involved; keep decisions in the request row itself (history by status and stamps), do not delete rows.
- **Org scoping:** every read and write is limited to the caller's organisation.

## 4. Database deliverables (typed in full in the chat)

For `20261106100000_technician_leave_request`:
1. Migration (extend the existing leave table; new columns for status, requested-by, decision note, approver, decided-at; new setting `leave_notice_days`; the protected-leave SQL function used by the KPI).
2. Rollback.
3. Test file: use a throwaway `__TEST_` organisation. Cover at least:
   - technician requests in advance, master approves, KPI excludes those days;
   - technician requests late (inside the notice window), master approves, KPI does **not** exclude;
   - master rejects; technician cancels; master revokes (days return to the KPI);
   - technician cannot approve their own request or anyone's;
   - one technician cannot see another technician's requests;
   - overlap and date validation are refused by the database;
   - the existing AMC leave trigger still works;
   - a real organisation's data is unchanged (relative fingerprint taken before the migration, compared at the end).
4. Rehearsal wrapper, standard form: ONE `DO` block; refuses when `(clock_timestamp() at time zone 'Asia/Kolkata')::time < time '18:00'`; embeds the migration and test text with sha256 recomputed and pinned in the block; runs them with `EXECUTE`; no top-level begin/commit/savepoint/rollback; ends in an unconditional `RAISE EXCEPTION 'RESULTS…'`; never concatenated with the migration in the request.
5. All hashes as sha256 of the LF blobs.

## 5. Front-end deliverables

- Technician app: Request leave screen, My leave list, cancel.
- Admin app: Leave requests page, approve/reject/revoke, assigned-visit warning, nav badge, notification link.
- Technician table: "days excluded due to approved leave" shown.
- `tsc` clean; vitest passing; new tests for the notice rule, the status transitions and the KPI exclusion helper.
- The front end must not crash if the migration is not applied yet (deploy-order safety): treat missing columns/functions as "feature unavailable".

## 6. Deploy order (write into the design note)

1. Rehearsal (rolled back, after 18:00 IST).
2. `GO APPLY` from the reviewer, backups first, version registered in the same transaction.
3. Deploy the web app (Vercel).
4. Capacitor rebuild and sync so the technician screen appears on phones.
5. Phone test as the test technician; approve as master.

## 7. Manual test script (include in the design note, about 10 lines)

As the test technician: open Request leave, pick a start date 3 days ahead, submit; see it as Pending. As master: open Leave requests, see the badge, approve; confirm the warning lists any assigned visits. As the test technician: see Approved and the notification. As master: check the technician table shows the excluded days and the KPI is unchanged. Repeat with a request starting tomorrow-in-less-than-notice-days: it must show "Late (KPI not protected)". Revoke one: the KPI days return.

## 8. Defaults chosen (the owner confirms with the client later; all are settings or easy to change)

- Notice: 1 day (`leave_notice_days`).
- Approval required: yes (master or operation_admin).
- Maximum request length: 30 days.
- Leave created directly by master/ops: decide and state; recommended: protected only if it also meets the notice rule.
- If you meet a conflict between this document and the code, say so in the plan.

## 9. Acceptance

- A technician can request leave in advance and see its status.
- A master can approve, reject and revoke from the admin app.
- Approved in-advance leave does not reduce the KPI; late, rejected, cancelled and revoked leave does.
- No WhatsApp is sent. No real customer is affected.
- All tests pass locally; the migration, rollback, tests and wrapper are typed in the chat with hashes.
- Nothing was run against the database. Nothing was pushed to `main`.
