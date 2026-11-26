# Feature: pin-autocorrect

Status: BUILT, migration NOT applied (needs owner's "GO APPLY"), not pushed. Builds on `arrival-location-lock`.

## Purpose
Arrival is a hard block outside 250 m of the saved pin. When the pin is wrong or missing, the technician is stuck at the customer's door, and the office only hears about it 5 minutes later. Owner (2026-11-26): "automate and skip the manual work". So: no office approval anywhere.

## Decision (how top products do it)
- Amazon and Swiggy learn a customer's true location from where drivers actually stop, and correct the geocode automatically. Field-service apps (ServiceTitan, Jobber) GPS-stamp clock-ins instead of approving them.
- Our rules, decided automatically:
  - Within the radius: normal arrival, locks the pin (existing).
  - 250 m to `settings.pin_autocorrect_max_m` (default 2000), or no pin: the technician taps "I'm at the customer — pin is wrong" (selfie + GPS accuracy of 75 m or better). The visit starts, the pin moves to their GPS, and the office gets an FYI notification (no task).
  - The corrected pin is **not locked**. The next normal in-radius arrival locks it, so two independent visits must agree. This guards against starting from somewhere else.
  - Beyond the max, or the pin is already locked: hard block plus the existing 5-minute office alert.
- This reverses the 2026-09-15 "hard block only" decision for the correctable band. Recorded in MEMORY.md.

## Architecture
- Migration `20261215100000_pin_autocorrect.sql`:
  - `settings.pin_autocorrect_max_m`.
  - `address_location_events.event` gains `'corrected'`.
  - `record_technician_pin_correction(org, ticket, lat, lng, accuracy) returns text`, SECURITY DEFINER. It:
    - checks the caller is the assigned technician;
    - requires accuracy of 75 m or better;
    - returns `locked` for a locked pin;
    - re-checks the distance band against the server settings;
    - updates lat/lng/pinned_at/accuracy, logs a `corrected` event (previous and new pin, distance), and sends a `pin_autocorrected` notification to operation_admin (failure-safe).
  - EXECUTE revoked from anon.
- App:
  - `arrivalMode()` in `lib/offline/geo.ts` mirrors the server checks.
  - MapPage: "pin is wrong" / "start here" button when correctable; reasons shown for too far, coarse GPS, or locked; arrival card also on the no-pin screen.
  - New outbox kind `location.pin_correction` (offline-safe).
  - Customer header chip via `pinStatus()`: Verified on site / Corrected by technician — confirms next visit / Location pinned / Not pinned.

## Impact map
| Touches | Risk |
|---|---|
| `addresses` lat/lng | Only unlocked rows. The lock guard is unchanged; a locked pin returns `locked` before any write. |
| `record_technician_arrival_address` | Unchanged. Locks the corrected pin on the next in-radius arrival. |
| Arrival-mismatch alert (live) | Unchanged; still fires for too-far or locked cases after 5 min outside. It can also fire while a correctable technician waits more than 5 min before tapping. Acceptable. |
| `service_visits` start | Unchanged; the visit starts via the existing outbox path. |
| Offline outbox | New kind added to the contract test. Server re-checks at sync time, so a stale queued fix can't move a pin that got locked meanwhile. |
| Settings cache | `select("*")` already includes the new column; the client falls back to 2000 if it's missing. |

## Edge cases
- Coarse GPS or no accuracy: no correction offered; the server returns `bad_fix`.
- Offline: the visit starts locally; the correction syncs later and the server re-decides.
- Client/server disagree (settings changed meanwhile): the visit has still started, but the server refuses to move the pin (`too_far` / `inside_radius`). Safe direction.
- Technician gaming from home within 2 km: the pin moves but isn't locked. The next technician at the real house is out of range of the bad pin, so it gets corrected again (or blocked). Every correction is in `address_location_events` with technician_id for review.
- Office edits the pin after a correction: the chip goes back to "Location pinned".

## Acceptance criteria
1. A correction 1.1 km off with 20 m accuracy moves the pin, does not lock it, logs one `corrected` event, sends one notification, and creates no task.
2. The next in-radius arrival at the corrected pin locks it.
3. A locked pin is never corrected.
4. Inside the radius, beyond the max, accuracy above 75 m, or missing accuracy: nothing changes.
5. No pin: the technician's location becomes the pin, with a null distance.
6. An unassigned technician gets `not_assigned`; a non-technician is rejected.
7. anon has no EXECUTE.
8. The client `arrivalMode` matches 1/4/5; the customer chip shows the four states correctly.
