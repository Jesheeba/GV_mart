# Feature: Unified "Log Interaction" sheet (merge Log Outcome + Reschedule + Today's Conversation)

## Purpose
Today a staff member logging a call has to pick between three separate, disconnected entry points on the same lead:
1. **Log Outcome** (`LogOutcomeSheet` → RPC `log_lead_outcome`) — contact was made; sets stage + postpone_count + next follow-up.
2. **Reschedule** (`RescheduleDialog` → RPC `reschedule_followup`) — no contact; just pushes the follow-up date; bumps postpone_count.
3. **Today's Conversation / Add Note** (inline textarea → RPC `add_lead_note`) — free text only; touches neither stage, postpone_count, nor follow-up.

All three already write into the same read-side feed (`lead_timeline`), but writing requires three different buttons and three different mental models, so staff either skip the note, log the wrong one, or do two actions back-to-back (e.g. log outcome then separately add a note). This feature gives one sheet with one decision ("did you reach the customer?") that routes to the right existing RPC, so the lead "moves" (stage, postpone_count/stuck flag, next follow-up, reminder) correctly no matter which path the user takes, in one submit.

## Architecture
**No new table, no new write-RPC.** Per Ponytail: the three RPCs already do the right thing server-side; the gap is purely client-side (three dialogs → one). Reuse `log_lead_outcome`, `reschedule_followup`, `add_lead_note` exactly as they are.

New component `LogInteractionSheet.tsx` replaces `LogOutcomeSheet.tsx`, `RescheduleDialog.tsx`, and the inline note toggle on `LeadDetailPage.tsx` (one entry point, one "Log interaction" button, used from both `LeadDetailPage.tsx` and `MyDayPage.tsx`).

Top-level choice inside the sheet, shared `note` textarea across all three (so switching mode never loses typed text):
- **Mode A — Reached the customer:** outcome chips (existing taxonomy) → on save calls `log_lead_outcome(p_note=note, ...)`. Next-follow-up fields pre-filled by `scheduleNext()` (existing helper in `lead-outcome-followup.ts`), editable.
- **Mode B — Didn't reach them / pushing it:** reason + new date/time → on save calls `reschedule_followup(p_reason=reason, p_note=note, ...)`.
- **Mode C — Just a note, nothing changes:** note only, no stage/follow-up change → on save calls `add_lead_note(p_note=note)`.

Won/lost leads: Mode A/B are hidden; sheet shows the existing `reopen_lead` flow instead (unchanged behavior, just reached from the same single button instead of a separate one).

**Correction after reading the actual files:** neither `LogOutcomeSheet.tsx` nor `RescheduleDialog.tsx` has a reminder checkbox today — the reminder selector built in `followup-workspace-reminders` only exists on `SetFollowupDialog.tsx` (first-time scheduling), with reminders-on-reschedule an explicitly documented, still-open gap. `LogInteractionSheet.tsx` therefore carries no reminder UI in any mode; it is not this feature's job to close that gap.

## Impact map
- `LeadDetailPage.tsx` — remove the two separate dialog-open buttons + inline note toggle/input (lines ~169-192, ~206-207 per last audit); replace with one "Log interaction" button opening `LogInteractionSheet`.
- `MyDayPage.tsx` — same swap at its outcome/reschedule open calls (~lines 302, 322).
- `CallReturnPrompt.tsx` — **must not be dropped.** This mounts `LogOutcomeSheet` globally in the admin shell and auto-opens it when staff return to the app after tapping "Call" on a lead (tab blur → focus), via `markLeft`/`takeReturnedCall` (`src/lib/call-return.ts`). This is likely the single most-used entry point into outcome logging, not just a secondary UI. `LogInteractionSheet` must accept the same controlled `lead`/`open`/`onOpenChange`/`defaultChannel` props and default into Mode A (reached customer) pre-selected, since a call-return implies contact was attempted; staff can still switch to Mode B/C inside the sheet if the call didn't connect.
- `LogOutcomeSheet.tsx`, `RescheduleDialog.tsx` — logic (outcome chips, `scheduleNext`, reason field, postpone-count copy) migrates into `LogInteractionSheet.tsx`; old files deleted only after `CallReturnPrompt.tsx` is repointed at the new component and the auto-open-after-call behavior is verified end to end, not kept as dead code.
- `lead-outcome-followup.ts` — reused as-is (`canSaveOutcome`, `scheduleNext`, etc.), no signature changes expected.
- `useLogLeadOutcome`, `useRescheduleFollowup`, `useAddLeadNote` hooks — reused as-is; verify all three invalidate the same query keys (lead detail, lead list, My Day tabs) so the lead visibly "moves" tabs/lists immediately after any of the three modes.
- `LeadTimeline.tsx` / `lead_timeline` RPC — unaffected (already unifies reads).
- `followup-workspace-reminders` feature (`createTask`, reminder selector) — lives only in `SetFollowupDialog.tsx`, unaffected by this merge; not pulled into `LogInteractionSheet.tsx`.
- `reopen_lead` flow — unaffected, just invoked from the same button for won/lost leads.

## Edge cases and failure modes
- Switching modes mid-fill must preserve the shared note text (state lives above the mode switch, not inside each mode's subform).
- Lead has an existing open follow-up and user picks Mode B (reschedule) — must cancel the old `lead_followups` row and create the new one (existing RPC behavior), not leave two open follow-ups.
- `postpone_count` nearing the stuck threshold (`lead_stuck_postpones`, currently 3) — show a visible warning before submit if this action will push the lead to "stuck." Implemented for Mode B only: `reschedule_followup` unambiguously bumps `postpone_count` when pushed later (documented in the RPC/dialog itself). Mode A has no client-visible field on `lead_outcomes` saying which outcomes count as a postpone server-side (that logic is internal to `log_lead_outcome`'s SQL) — rather than guess and risk a wrong warning, none is shown there. Flagged here as a known limitation, not silently dropped.
- Mode C (note only) on a lead with an overdue follow-up must NOT silently clear or resolve that follow-up — it stays open/overdue exactly as before.
- Won/Lost lead opened in My Day (shouldn't normally appear there, but defensive check) — route to `reopen_lead`, never to Modes A/B.
- No duplicate/competing note-write path left after this ships — only one of the three RPCs fires per submit, never two.

## Acceptance criteria
- [x] One "Log interaction" entry point on `LeadDetailPage.tsx` and `MyDayPage.tsx`; old separate Outcome/Reschedule buttons and inline note toggle are gone. **Update 2026-11-12:** the quick "Reschedule" button on `FollowupCard.tsx`/`LeadDetailPage.tsx` was dropped too, per owner request ("log interaction and reschedule have mostly the same, combine together into the log interaction") — reschedule is reached only via the mode switch inside the sheet now, down to exactly one button everywhere.
- [x] `CallReturnPrompt.tsx` still auto-opens the merged sheet (defaulted to Mode A, `defaultChannel="call"`) after a staff member returns to the app post-call; switching to Mode B/C from there still works (same shared mode-switch UI, no special-casing needed).
- [x] Mode A (reached) writes exactly one `log_lead_outcome` call; stage/postpone_count/next-follow-up update per existing RPC logic; lead moves tabs in My Day and status tiles on Leads list without a page refresh (verified via shared query-invalidation keys in `useLeadFollowups.ts`).
- [x] Mode B (reschedule) writes exactly one `reschedule_followup` call; old follow-up cancelled, new one created, postpone_count bumped only when pushed later (existing rule, unchanged).
- [x] Mode C (note only) writes exactly one `add_lead_note` call; no follow-up/stage/postpone_count change.
- [x] Switching between modes before submit never loses the typed note (single shared `note` state above the mode switch).
- [x] Reminder creation unaffected by the merge. **Correction to this doc's own architecture section:** neither `LogOutcomeSheet.tsx` nor `RescheduleDialog.tsx` ever had a reminder checkbox — checked the actual files before building, not assumed. The reminder selector only exists in `SetFollowupDialog.tsx` (per `followup-workspace-reminders`' documented gap: "reminders are not yet wired into Reschedule"). `LogInteractionSheet.tsx` correctly carries over zero reminder code in any mode, matching reality; closing that pre-existing gap is out of scope here.
- [x] Won/Lost leads open the reopen flow instead of Modes A/B from the same button.
- [x] `LogOutcomeSheet.tsx` and `RescheduleDialog.tsx` deleted (not left as dead/unused files) — confirmed no remaining references anywhere else in `src/` before deleting.
- [x] Regression pass on `followup-workspace-reminders` and `lead-detail-fields` acceptance criteria (both touch the same page/components) — `tsc --noEmit` clean, `oxlint` clean, full leads pure-logic suite (52 tests) unchanged/passing.
