# Feature: arrival-location-lock

Status: BUILT + migration APPLIED LIVE 2026-11-26 (approved + "go apply"). See TESTING.md.

## Purpose
A technician's confirmed on-site arrival is the most trustworthy location an address can have. Today it is saved silently, can be overwritten on every visit or by any later edit, and records no trace of who set it. The goal is to save it once, compare it with the previous pin, and lock it as final.

## Owner decisions (2026-11-26)
- Lock happens **once per address**, on the first technician arrival confirmation. Later arrivals never move it.
- **Only master** can unlock it, with a "Reset verified location" action and a required reason. The next arrival then re-locks it.
- Arrival at a **secondary address does NOT make it primary**. It only locks that address's pin. This replaces today's swap-and-copy logic, which also removes the bug where the copy dropped full_address, sub_area, zone and water_*.
- **Editing address text never touches a locked pin.** The form's "text changed, clear pin" logic is skipped for locked addresses.

## Architecture
**DB (one migration):**
- `addresses` + `location_verified_at timestamptz`, `location_verified_by uuid` (technicians.id). NULL means not locked.
- New append-only `address_location_events`: `id, org_id, address_id, event ('verified'|'reset'), technician_id, actor_profile_id, ticket_id, prev_lat, prev_lng, new_lat, new_lng, distance_m, accuracy_m, reason, created_at`. This answers "customer location vs technician location". RLS: staff select in own org; no direct insert/update/delete (RPC only).
- `record_technician_arrival_address(p_org_id, p_ticket_id, p_lat, p_lng, p_accuracy_m default null)` is rewritten:
  1. Caller must be the ticket's assigned technician (as today).
  2. Address already locked → return, no change.
  3. No previous pin → return (the no-pin case belongs to the parked pin-trust design).
  4. **Server-side geofence**: the distance from the previous pin must be within `geofence_radius_job_m`, and accuracy (if sent) at most 75m. Otherwise return without locking. Today only the app enforces this, so a modified client could lock any coordinates.
  5. Atomic `update ... where location_verified_at is null` sets lat/lng/pinned_at/location_accuracy_m/verified_at/verified_by, and an event row stores the previous pin, the new pin and the distance. If two arrivals race, the first wins.
- `reset_address_location_verification(p_address_id, p_reason)`: master only, reason required. Clears verified_at/by (keeps the pin) and logs a 'reset' event.
- **Guard trigger** `BEFORE INSERT OR UPDATE ON addresses`: while locked, rejects any change to lat/lng/verified_* unless the two RPCs above set a transaction-local flag. Clients can never set verified_* themselves. This covers every write path (office form, customer app setMyAddressPin/clearMyAddressPin, AddressPinDialog, any RPC).
- Explicit `revoke ... from public, anon` on the new functions (project auto-grants EXECUTE to anon).

**App:**
- MapPage: send `position.accuracy` with the arrival (outbox payload gains optional `accuracyM`; the old queued payloads still work).
- CustomerFormPage: a locked address shows a "Verified on site by <technician>, <date>" badge. The map is read-only (no search, drag, or auto-locate), and text edits keep the pin. Master sees "Reset verified location" with a reason dialog.
- Customer app address screen and AddressPinDialog: a locked address hides change/clear pin and shows "Location verified by our technician".
- `database.ts` hand-patched (no Docker for gen types).

## Impact map
| Touches | Risk |
|---|---|
| `record_technician_arrival_address` (signature change: drop and recreate) | GRANTs drop with DROP FUNCTION and must be re-granted. Queued offline items without accuracy must still work (default null). |
| `addresses` guard trigger | Any existing path that rewrites lat/lng on a locked address now errors. The office form must send unchanged lat/lng, and the customer app must hide pin edits. |
| `customers.ts` upsertAddress, `customerApp.ts` pin functions, `AddressPinDialog` | Must not attempt locked-pin changes. The UI hides those actions. |
| `CustomerFormPage` stale-pin effect and auto-locate | Must be skipped when locked, or the form would try to clear the pin and hit the trigger. |
| Arrival-mismatch alert (live) | Unchanged. A wrong pin more than the radius away still blocks Reached and raises the office task. The office fixes the pin, then the next arrival locks it. |
| Parked pin-trust design | This is its top "technician on site" tier only. It doesn't conflict, and the rest stays parked. |

## Edge cases
- Pin wrong by more than the radius: Reached stays blocked, so it never locks a wrong place. The mismatch alert fires instead.
- Poor GPS (accuracy above 75m) or a missing previous pin: arrival still succeeds for the visit, but the address is not locked.
- Offline arrival synced hours later: locked at sync time; the event keeps ticket_id.
- Two technicians or a duplicate outbox replay: the atomic `where verified_at is null` means one lock and one event.
- Customer moves house: master resets, or office adds a new address (new rows are never locked).
- Existing pins: no backfill. We can't tell which past pins came from an arrival, so each address locks on its next confirmed arrival.

## Acceptance criteria
1. First in-radius arrival with accuracy of 75m or less locks the address and logs one 'verified' event with the previous pin, new pin and distance.
2. A second arrival at a locked address changes nothing and logs no event.
3. Arrival at a secondary address locks it, and `is_primary` is unchanged on every address of that customer.
4. An RPC call with coordinates beyond the radius, or accuracy above 75m, does not lock.
5. A direct update of lat/lng or verified_* on a locked address (any role, via PostgREST) is rejected.
6. Office text edit on a locked address saves and the pin stays.
7. Master reset clears the lock, logs a 'reset' event with the reason, and non-master is rejected.
8. A non-assigned technician calling the RPC changes nothing.
9. anon has no EXECUTE on the new or changed functions.

## Tests
- SQL test file run in ONE transaction opened and rolled back by me, ending in `RAISE` (never concatenated with the migration). It covers criteria 1–5, 7–9.
- `tsc` and the existing vitest suite; browser check of criterion 6 and the badge/reset UI on the local dev server.
- Migration is applied live **only when the owner names it**.
