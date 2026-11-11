# Feature: Follow-up workspace — today's conversation, next follow-up, reminder

## Purpose
Let staff log today's conversation, set the next follow-up date/time via the existing scheduling system, and optionally create a reminder — wired into the existing `lead_activities`/`lead_followups`/`tasks` systems rather than new ones.

## Architecture
- **Today's conversation** → on save, `insert into lead_activities (lead_id, org_id, type, note, at, created_by)` — same shape as the existing inline "Add Note" action on `LeadDetailPage.tsx` (verify whether this is already exactly that action before adding a second, possibly-duplicate note path).
- **Next follow-up date/time** → reuse existing `SetFollowupDialog`/`set_lead_followup` RPC; the prototype's two bare `<input type=date>`/`<input type=time>` become that dialog's fields, not a new write path.
- **Reminder** → `createTask` in `workspace.ts` with `source: 'lead_followup_reminder'`, `ref_type: 'lead'`, `ref_id: lead.id`, `due_at` derived from the chosen next-follow-up datetime and the selected lead-time option (At follow-up time / 15 min before / 1 hour before / 1 day before).
  - **Must verify first:** does `CreateTaskInput` (workspace.ts) currently accept `ref_type`/`ref_id`? Survey found the columns exist on `tasks` but no confirmed call site passes them. If the TS helper doesn't expose them yet, extend `CreateTaskInput`/`createTask` (additive optional params) rather than inserting into `tasks` directly from a new code path.

## Impact map
- `LeadDetailPage.tsx` — "Add Note" inline action and the new "Today's conversation" textarea must not become two divergent ways to write `lead_activities`; converge on one.
- `SetFollowupDialog.tsx` — reused, not duplicated.
- `workspace.ts` — possibly extended `CreateTaskInput`; check all existing callers of `createTask` still compile/behave identically (optional params only).
- `MyDayPage.tsx` / task list views — new `ref_type='lead'` tasks will appear in whatever already lists tasks by assignee; confirm they render sensibly (e.g. title/description references the lead) and don't break existing task-list filters that assume `ref_type` is always null or another value.

## Edge cases and failure modes
- No reminder selected → no task created; next-follow-up still saved via `lead_followups` regardless.
- Lead has no assignee when a reminder is requested → reminder's `assignee_id` should default to the current user (the person logging the conversation), not fail.
- Rescheduling an existing follow-up → should not create a duplicate orphan task; if a task already exists for that follow-up, update/cancel it rather than piling up reminders (needs its own small design check during implementation — not fully specified yet, flag if ambiguous when building).

## Acceptance criteria
- [ ] Today's conversation textarea writes one `lead_activities` row with correct actor and timestamp.
- [ ] Next follow-up date/time flows through existing `set_lead_followup` RPC, visible in `leads.next_followup_at`.
- [ ] Reminder creates a `tasks` row with `ref_type='lead'`, `ref_id=<lead.id>`, due at the correct offset.
- [ ] Follow-up history list shows date, note, and owner (reads `lead_activities`, newest first).
- [ ] No duplicate/competing "add note" code path left in the codebase after this feature ships.
