# Item 13 — Post-service follow-up call (design)

Status: BUILT LOCALLY, NOT APPLIED, NOT PUSHED. Decisions from the owner: generalise `lead_followups` (option 3), recipient = all
sales staff by default (master can change), delay default 2 days (master-editable), one follow-up per completed ticket, outcome
recorded through a Log-outcome-style sheet, appears in Daily Follow Up.

## 1. What the owner gets
When a service ticket becomes **completed**, a "Post-service call" shows up in Daily Follow Up two (configurable) working days
later. Staff call the customer, tap **Log call**, pick an outcome (Satisfied / Problem not solved / Couldn't reach — call later …),
add a note. The result is stored against the ticket; a "problem" outcome alerts the master and operations.

## 2. Schema (Phase 1, additive; nothing existing changes meaning)

`lead_followups` (the existing table, generalised):

| change | detail |
|---|---|
| `lead_id` | `DROP NOT NULL` |
| `ticket_id uuid` | new, `references service_tickets(id) on delete cascade` |
| `customer_id uuid` | new, `references customers(id) on delete cascade` — set for ticket rows (who to call) |
| `assigned_to uuid` | new, `references profiles(id) on delete set null` — NULL = all sales staff (same meaning as an unassigned lead) |
| CHECK `lead_followups_lead_xor_ticket` | exactly one of `lead_id`, `ticket_id` is not null. Every existing row has a lead, so it holds today |
| unique index `lead_followups_one_per_ticket` | `(ticket_id) where ticket_id is not null` → **one follow-up per ticket, ever** (the idempotence guard) |
| existing unique index `lead_followups_one_open_per_lead` | unchanged (a NULL lead_id never collides) |

"post_service type": the **channel** `type` stays `call` (the enum `lead_followup_type` is not extended, so an old browser bundle
never meets an unknown value). The *kind* is `source = 'post_service'`, exactly how `initial_call`, `outcome`, `reschedule` are
already distinguished.

New tables:
* `post_service_outcomes` — master-editable list (org_id, code, label_en, label_ta, `retry` bool, `alert` bool, is_active,
  is_system, sort_order). RLS: select org staff, write master; audit trigger; seeded per organisation (also by a trigger on new
  organisations). Seeds: `satisfied`, `issue_remaining` (alert), `not_reachable` (retry), `call_later` (retry), `no_answer_needed`.
* `post_service_calls` — one row per call attempt: (id, org_id, followup_id, ticket_id, customer_id, outcome_id, outcome_code,
  note, called_by, called_at). RLS: select sales/ops staff; **no client write policy** (RPC only).

`settings` (master-editable, all with safe defaults):

| column | default | meaning |
|---|---|---|
| `post_service_followup_enabled` | **false** | on/off. OFF so applying the migration changes nothing until the master switches it on |
| `post_service_followup_days` | 2 | delay after completion, 0–60 days |
| `post_service_followup_assignee` | NULL | NULL = all sales staff; or one profile (master/sales_admin) |
| `post_service_ticket_types` | `{paid,warranty,installation}` | which ticket types get a call (AMC and rental visits are routine and excluded by default; `ticket_type` also has amc, rental) |
| `post_service_dedupe_days` | 0 | skip if the same customer already has a post-service follow-up created in the last N days (0 = off, i.e. strictly one per ticket) |

## 3. Trigger point and rules
`AFTER UPDATE OF status ON service_tickets WHEN (new.status = 'completed' AND old.status IS DISTINCT FROM 'completed')`
(`_trg_ticket_post_service_followup`, SECURITY DEFINER). One trigger covers **every** completion path
(`create_service_invoice`, `complete_appointment`, admin edits) so no completion RPC is modified. Steps:
1. feature enabled? ticket type in the master's list? dedupe window clear? — otherwise nothing is written.
2. due = IST date of completion + N days, **rolled forward to the next working day** (`lead_work_days`), at
   `lead_work_start + 30 minutes` (same convention as the initial-call and bulk-spread slots).
3. insert `source='post_service'`, `type='call'`, `ticket_id`, `customer_id`, `assigned_to` (the master's chosen person, if still
   an active sales person; else NULL), note "Post-service call".
4. `ON CONFLICT (ticket_id)` does nothing → a ticket that is reopened and completed again does **not** get a second call.
5. The insert is wrapped so a failure only raises a WARNING: a bug here must never stop a technician completing a job.

## 4. Reading it (functions)
* **`list_followups` — NOT modified.** It is an inner join on `leads`, so post-service rows are naturally excluded; its return
  type and every lead filter stay as they are. A **new sibling** `list_post_service_followups(p_bucket, p_scope, p_assignee)`
  returns the ticket rows (customer, mobile, ticket complaint/type, due, bucket, assignee, attempts, last outcome). Daily Follow
  Up calls both and merges by due date. No duplicate signature, no changed return type.
* **`followup_counts`** — same signature, `create or replace`: overdue/today/total and `by_person` now also count open ticket
  follow-ups (same scope rules; `assigned_to IS NULL` ≙ unassigned). This feeds the **sidebar badge**.
* **Daily digest (`run_lead_followup_notifications`)** — same signature, `create or replace` from the LIVE body. The lead
  sentences are untouched; when the recipient has post-service calls due/overdue it appends " N post-service call(s) due." and the
  digest is also sent when that is the only thing to report. (The 24-hour-overdue list and the exact-time reminders remain
  lead-only — listed as a known limitation.)
* **No follow-up tab** (`list_leads_without_followup`) — untouched: it asks "does this *lead* have an open follow-up", ticket rows
  have no lead.
* **`lead_timeline`, `set_lead_followup(s)`, `reschedule_followup`, `reopen_lead`, `log_lead_outcome`, close/reopen triggers,
  `_trg_followup_sync_next`** — all key on `lead_id`; with `lead_id` NULL they match nothing, so they are untouched and ticket rows
  never alter `leads.next_followup_at`, `postpone_count` or any stage.
* **Log Outcome sheet (item 17)** — unchanged and not used for these rows. Post-service rows use their own small sheet.

## 5. Recording the outcome
`log_post_service_call(p_followup_id, p_outcome_id, p_note, p_next_due_at)` (SECURITY DEFINER, sales staff only):
* writes a `post_service_calls` row (note capped at 2000 chars);
* outcome with `retry = true` ("couldn't reach", "call later"): a new date is **required**; the *same* follow-up stays open with
  the new `due_at` (so the one-per-ticket rule holds) and every attempt is kept in `post_service_calls`;
* any other outcome: the follow-up is marked **done** (completed_by/at);
* outcome with `alert = true` ("problem not solved"): a notification goes to every active master and operation_admin, linked to
  the ticket.
Only rows with a ticket can be logged; a lead follow-up id is rejected, and a done/cancelled row cannot be logged twice.
The ticket page shows the call history.

## 6. What must NOT change (and how it is guaranteed)
* **Lead counts, conversion, the lead funnel, every report**: nothing here touches `leads`, `lead_activities`, `lead_stage_log`
  or any `report_*` function; none of them reads `lead_followups` without a lead join (verified against the live function list).
  Tests assert the funnel and lead follow-up lists are identical with ticket rows present.
* **Existing follow-up numbers while the switch is OFF**: identical (no rows are created).

## 7. What does change once the master turns it on
Daily Follow Up gains post-service cards; the sidebar badge and the daily digest include them; `lead_followups` row counts rise
by one per completed ticket of an enabled type. Nothing else.

## 8. Phases
1. Migration (schema + functions, all additive; `list_followups` untouched) — safe to apply with the switch OFF.
2. Frontend: Daily Follow Up cards + sheet, Masters card (switch/delay/recipient/types + outcomes), ticket history card.
3. Master turns the switch on. (Rollback: switch off; the rollback file drops the objects and restores the live bodies of
   `followup_counts` and the digest.)

New functions: `REVOKE EXECUTE ... FROM PUBLIC, anon`; staff RPCs `GRANT ... TO authenticated, service_role`; trigger/seed
functions have no client grant.
