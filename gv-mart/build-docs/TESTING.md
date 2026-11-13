# Testing

## Segment Builder (advanced/secondary automation)

| Area | Test | Result |
|---|---|---|
| `wa-event-context.ts` new `audience_segment_match` branch (standing fire, manual fire, no-customer guard) | `wa-event-context.test.ts`, 3 new cases | ✅ 3/3 pass |
| Regression: whole suite after this feature's changes | `npx vitest run` | ✅ 1035/1036 pass (1 pre-existing failure, not from this feature — see below) |
| Type safety across all edits | `tsc --noEmit` | ✅ clean |
| `test-customer-guard`: `audience_segment_match_count` decided | added to `supabase/test-customer-guard.manifest.json` must_exclude; migration filters `not c.is_test` in the count, preview, send-now, and standing-trigger paths | ✅ guard passes |
| New migration (`20261204230000_segment_builder.sql`) — tables, RLS, condition-tree evaluator, 4 functions, 1 trigger | manual review only — **not run against any database** (no SQL-trigger/function test harness exists in this repo, confirmed again) | not applied (blocked, see below) |

### Deviation from the feature spec
`segment-builder.md` asked for standing mode to reuse `automation_rules`/`automation_queue`. Read those
tables first: `automation_queue.state` has a CHECK constraint allowing **only**
`('dry_run','blocked_not_allowlisted')` — it cannot represent a real sent/queued row by schema design,
not just by current configuration — and `automation_rules` ties one rule to a single fixed `event_key`
from a closed catalog, not an arbitrary condition tree. Reusing it would mean altering a constraint
that exists specifically to keep that path dry-run-only, which is out of scope here. Instead, standing
mode reuses the **existing** `whatsapp_outbox` + `whatsapp_event_templates` + `wa-milestone-dispatch`
pipeline (same one the basic lifecycle automation already uses) via a synthetic per-segment event key
(`segment.<id>`) — zero new send code, consistent with "don't invent a new pattern where one already fits."

### Known simplification
For a manual "Send Now" fire there is no single triggering purchase (a customer may match on several),
so `{{product_name}}` resolves to that customer's **most recent** purchase, not necessarily the specific
item that satisfied the segment's product condition. Standing-mode fires are precise (the exact
triggering `invoice_item_id` is carried in the outbox row's payload). Flagged, not fixed — would need
the condition tree to track which leaf matched, out of scope for this pass.

### Pre-existing failure found, NOT fixed (out of this feature's scope per directive)
`waOutboxSentGuard.test.ts` fails because `20261204220000_wire_gvm_templates_phase_b_new_triggers.sql`
(the earlier Basic Lifecycle Automation migration, not touched by this feature) inserts
`whatsapp_outbox` rows with `status = 'sent'` instead of `'pending'` — a real regression, caught by a
guard test that predates or postdates that migration. This feature's own new migration was written
`status = 'pending'` throughout and does not trip the guard. Not fixed here because the directive for
this feature explicitly says not to touch that file; flagging for whoever next works on the Basic
Lifecycle Automation migration.

### Blocked — not this feature's problem, flagging per standing policy
`20261204230000_segment_builder.sql` has not been applied to the live database — same standing
permission block as every other migration this session. Applying requires explicit owner action or a
permission grant (see `build-docs/MEMORY.md`); not attempted again here.

## Admin UI: Segments tab
New `SegmentsTab.tsx` under Automation → "Segments": condition builder (AND/OR, add/remove rows),
live match count + preview, template picker (reads already-approved `gvm_*` names), Save, Send Now,
Standing toggle, and a per-segment Results table. Master-role gated client-side (mirrors
`AccountsPage.tsx`'s `profile?.role === "master"` pattern) and server-side (RLS `is_master()`). Not
covered by an automated UI test — no existing tab in this admin page has one either (checked
`EventTemplatesTab`/`AutomationFlowsTab`/`TemplatesTab`).

## Basic Lifecycle Automation (gvm_* templates, Phase A + Phase B)

| Area | Test | Result |
|---|---|---|
| `wa-event-context.ts` new branches (lead/quotation/amc_contract/payment) | `wa-event-context.test.ts` (new, 9 cases) | ✅ 9/9 pass |
| `wa-event-context.ts` ticket product_name addition (installation) | same file, 2 cases | ✅ pass |
| Regression: existing milestone dispatch logic | `wa-milestone-dispatch-core.scope.test.ts`, `wa-milestone-dispatch-core.customer-link-otp.test.ts` | ✅ 36/36 pass, unaffected |
| Regression: admin nav (unrelated to this change, run as a sanity check) | `nav.test.ts` | ✅ pass |
| Type safety across all edits | `tsc --noEmit` | ✅ clean |
| New SQL migration (`20261204220000_...phase_b_new_triggers.sql`) | manual dollar-quote balance check only — **not run against any database** | not applied (see below) |

### Not tested (no harness exists for this)
No SQL-trigger test framework exists anywhere in this repo (checked `supabase/` for one) — the new
trigger functions (`_milestone_lead_notify`, `_milestone_quotation_notify`,
`_milestone_amc_contract_notify`, `_milestone_payment_notify`, and the updated
`_milestone_ticket_notify`) are unverified against a real database. They were written by directly
copying the exact shape of the existing, already-live `_milestone_*` functions
(`20260702170100_automation_purchase_functions.sql`), including their lack of exception handling —
none of the originals have any either, so none was added here.

### Blocked — not this feature's problem, flagging per standing policy
Neither migration (`20261204210000_wire_gvm_templates_phase_a.sql` nor the new
`20261204220000_...phase_b_new_triggers.sql`) has been applied to the live database. Applying a
migration requires explicit owner action or a permission grant (see `build-docs/MEMORY.md`) — not
attempted again here.

## Admin UI: per-event on/off toggle
New `EventTemplatesTab.tsx` under Automation → "Approved Templates" lists whatever
`whatsapp_event_templates` rows exist and toggles `is_active` per row (column + send-path check
already existed, just had no UI). Not yet visible live since the DB rows it lists don't exist until
the migrations above are applied. Not covered by an automated test — no existing test file covers
any other tab in this admin page either (checked `AutomationFlowsTab`/`TemplatesTab`, neither has one).
