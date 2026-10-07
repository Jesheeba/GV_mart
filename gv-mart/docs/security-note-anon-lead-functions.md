# Read-only note: lead functions executable by `anon`

Prepared for the security review. Nothing here was changed, and no function was called against live data to prove the write paths (that would create real leads). Findings are from the live function bodies and ACLs (2026-10-07).

## What is exposed

| Function | Definer? | anon | authenticated | In-function auth check |
|---|---|---|---|---|
| `_whatsapp_lead_upsert(org, mobile, trigger, body)` | yes | **yes** | yes | **none** |
| `_find_recent_open_lead(org, customer, mobile, window)` | yes | **yes** | yes | **none** |
| `generate_enquiry_lead` (both overloads) | no (invoker) | yes | yes | yes: raises unless caller is a technician (`current_technician_id()`) |
| `simulate_inbound_whatsapp(org, mobile, body)` | no (invoker) | yes | yes | yes: `p_org_id = current_org_id()` and `is_staff()` |
| `wa_create_lead` | yes | no | no | n/a (service role only) |

So `generate_enquiry_lead` and `simulate_inbound_whatsapp` are anon-executable but harmless: they fail for anonymous callers, and the first runs under RLS. The real exposure is the two helpers `_whatsapp_lead_upsert` and `_find_recent_open_lead`.

## Who calls them, and why they are open

- `_whatsapp_lead_upsert` is called by `wa_create_lead` (service role, from the WhatsApp Edge Function `whatsapp-handle-message.ts`) and by `simulate_inbound_whatsapp` (staff, in-app simulator). `_find_recent_open_lead` is called only by `_whatsapp_lead_upsert`.
- No client code calls either directly. They are open because this project auto-grants EXECUTE on every new public function to `anon` and `authenticated` (see the earlier default-privileges finding); the later `wa_*` clean-up revoked the wrappers but not these two internals, and `simulate_inbound_whatsapp` (invoker) still needs `authenticated` to reach `_whatsapp_lead_upsert`.

## What an anonymous caller can do

With only the public anon key (REST `POST /rest/v1/rpc/...`) and a valid organisation UUID:

- **Create leads** in that organisation: `_whatsapp_lead_upsert` inserts into `leads` (source `whatsapp`, status `new`) and `lead_activities`, and inserts a `wa_lead_captured` notification for sales staff (mirrored to the master). It runs as definer, so RLS does not apply. It can be repeated without limit, so this is a spam / pipeline-pollution path. If a customer mobile matches an open lead within 30 days it appends an activity to that lead instead, so an attacker can also write text into an existing lead's history.
- **Probe whether a mobile number has an open lead**: `_find_recent_open_lead` returns the lead UUID of an open lead for a given mobile (or customer) in the org. That confirms customer/lead existence and leaks internal ids.
- **Read other tables?** No. Neither function returns table data other than that lead UUID; `generate_enquiry_lead` and `simulate_inbound_whatsapp` stop at their checks.
- Limiting factor: the caller needs the organisation UUID. There is one organisation today; the id is not secret in the sense that it appears in authenticated app traffic, so treat it as guessable by anyone with an account.
- Interaction with round robin: once auto-assign is on, each forged lead would also be assigned to a sales person and notify them.

Any **authenticated** user (customer, technician, any org) has the same access, so a logged-in customer could write leads into another organisation.

## Proposed fix (additive migration, not applied)

1. `REVOKE ALL ON FUNCTION public._whatsapp_lead_upsert(uuid,text,enquiry_type,text) FROM PUBLIC, anon, authenticated;` and the same for `_find_recent_open_lead(uuid,uuid,text,interval)`.
2. Keep the in-app simulator working: make `simulate_inbound_whatsapp` `SECURITY DEFINER` with `SET search_path = public`. Its own org-match and `is_staff()` checks already gate it (they read `auth.uid()`, which is unchanged under definer), and a definer function can still call the revoked helper.
3. `REVOKE EXECUTE ON FUNCTION public.generate_enquiry_lead(...)` (both overloads) `FROM PUBLIC, anon` (keep `authenticated`; technicians call it). Optional hardening.
4. Test (live, rolled back): anon and a customer JWT get "permission denied" on both helpers; the master/staff simulator and the WhatsApp Edge Function path (`wa_create_lead`) still create leads.
5. Add a default-privileges safeguard or a CI check that fails when a new public function is executable by anon without being on an allow-list.
