# Master-defined questions for follow-up calls

Status: BUILT on `feat/followup-questions`, NOT applied (migration `20261027100000_followup_questions`). Builds on item 13 (`design-item13-post-service-followup.md`).

## What it does
The master keeps a list of questions (Masters > Post-service calls > Questions). The Log call sheet shows the active ones for that call; the answers are saved in the same transaction as the call outcome. Customer and ticket pages list the answers; the master gets a read-only per-question report.

## Decisions taken as defaults (client has not answered) and how each flips
| Open point | Default built | How to change it |
|---|---|---|
| Example questions | 6 seeded per organisation, **inactive**, Tamil blank | master edits, activates or replaces them |
| Post-service only, or lead calls too | `scope = 'post_service'` (NULL treated the same) | add a question with another scope by data; the lead sheet then needs to read that scope (no migration) |
| Questions differ by ticket type | link table; **empty = all types** | tick ticket types on the question row |

## Data
- `followup_questions`: text (en + ta), `answer_type` (yes_no, choice, rating 1-5, text), `choices`, required, active, sort order, nullable scope. `answer_type` is fixed after creation; **no delete** (deactivate).
- `followup_question_ticket_types`: optional restriction.
- `post_service_call_answers`: one row per question per call, with a **snapshot** of the question text (en/ta), type and choices; unique `(call_id, question_id)`; a CHECK rejects a value that does not match the snapshot type.
- `post_service_calls.followup_needed` (boolean, nullable).

## Rules
- Writes: questions and links by master only (RLS); answers only through `log_post_service_call` (SECURITY DEFINER, fixed `search_path`). Signature changed 4 to 6 arguments, so the old function is dropped, PUBLIC and anon revoked on the new one, authenticated granted. A call without answers behaves exactly as before.
- Required questions are enforced in the database. Not required when the outcome is a retry outcome (not_reachable, call_later) or `no_answer_needed`.
- Follow-up needed: there is one follow-up row per ticket, so a call can never create two. A retry outcome or "follow-up needed = yes" keeps the same row open at the new date; anything else closes it. A retry outcome stores NULL in `followup_needed`.
- Rating answers live only in `post_service_call_answers`. Nothing reads or writes `ratings` or `google_review_clicked`; there is no reward text and no per-technician review column.
- Report: master only, IST dates, max 366 days, test customers left out, free text is counted, never listed.

## Screens
Call sheet (questions, follow-up needed, scrolls, sticky Save, 44 px touch targets); Masters > Post-service calls (questions + report); ticket page card (answers added); customer page "Calls" tab (new).

## Estimate (days)
Built (DB 1.0, call sheet 0.5, masters + report 0.75, customer/ticket cards 0.25, tests and wrapper 0.5): **3.0**. Remaining: rehearsal and fixes 0.5, Capacitor device pass 0.5, Tamil review of UI strings and questions 0.5 (client).

## Not tested here
Capacitor build on a device, browser run of the new screens, the SQL tests (not run by instruction).
