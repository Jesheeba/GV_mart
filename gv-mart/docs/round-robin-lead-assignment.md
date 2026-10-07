# Round-robin lead assignment (database layer)

Migration `20261010100000_lead_round_robin.sql`. Role value stays `sales_admin` (label "Sales person").

## The switch ships OFF
`settings.auto_assign_leads` defaults to **false**, so applying the migration changes nothing. The owner turns it ON once the 2 real sales persons exist (and are active, with "Receives new leads" on):

    update settings set auto_assign_leads = true where org_id = '<org>';   -- master / SQL until the settings toggle is built

There is no settings-screen toggle yet (database-only phase); turning it on needs this one statement or a small UI follow-up.

## Behaviour
- Fires on **INSERT into leads only**, from every entry path. UPDATEs never fire it, so the leads that exist today can never be auto-assigned, and they are never flagged pending.
- Eligible: `role = 'sales_admin'`, `is_active`, `receives_new_leads`, same organisation. Master is excluded.
- Pick: least recently auto-assigned first (never-assigned first, then oldest profile, then id). Only auto assignments move the rotation; `assign_lead` never does. State is in `lead_rotation` (no client access).
- Each auto assignment writes a `lead_assignments` row (reason `auto round-robin`, no assigner) and a `lead_assigned` notification to the person.
- Nobody eligible while ON: the lead is saved unassigned with `auto_assign_pending = true`; the master gets one `lead_auto_assign_waiting` notice (no more while one is unread). Distribution of waiting leads is **not built yet** (design pending approval).
- Won/lost leads inserted by staff are not assigned. A client-supplied `assigned_to` is still rejected by `leads_assigned_guard`; a client-supplied `auto_assign_pending` is discarded on insert and cannot be updated.
- `profiles.receives_new_leads` can be changed from the client only by the master.
- All new functions are internal: `REVOKE ALL ... FROM PUBLIC, anon, authenticated`.

## Held
`supabase/held/20261010110000_staff_helpers_require_active.sql` (is_staff / is_sales_staff require `is_active` for sales_admin only) is written and tested in a rolled-back transaction, not applied.
