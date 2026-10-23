# Manual test: Mark Attendance location (fix/attendance-location)

Run on a real Android phone, in Chrome, at the shop. Covers the geofence location fix in
`src/app/technician/AttendancePage.tsx` + `src/lib/offline/geo.ts`.

Before starting, confirm the live office geofence settings (Masters > Settings > Travel):
office location and geofence radius. As of 2026-10-23 the radius is **100m**.

If anything behaves differently than expected, record:
- which case you ran
- what message/screen actually appeared (exact text, screenshot if easy)
- whether a spinner/"Getting a more precise location…" step showed up and for how long
- the fix's accuracy, if visible — Chrome doesn't show this in the UI, so open
  chrome://inspect or Chrome DevTools remote debugging on the phone and watch the
  Console/Network while on the Attendance screen; or temporarily add a `console.log`
  of `quick.accuracy` in `refreshLocation()` before testing, then remove it after

---

## 1. Indoors, away from a window, on Wi-Fi — should succeed quickly

**Steps**
1. Stand indoors, away from any window or door, with the phone's Wi-Fi on and connected.
2. Open the technician app, go to Mark Attendance.
3. Watch the location status line under "Mark Attendance" from page load.

**Expected**
- Resolves within a few seconds (not the old ~20-30s wait).
- No "Getting a more precise location…" message, unless you're genuinely near the 100m
  boundary — if you're well inside the shop, skip straight to "You are inside the office".
- No spinner stuck for more than ~15s.

**Record if different:** how long it took, whether it showed "Getting a more precise
location…" even though you were clearly well inside (would mean the quick fix's accuracy
was unexpectedly bad for an indoor Wi-Fi fix), and the accuracy value if you captured it.

---

## 2. Indoors, Wi-Fi off, mobile data only — escalation behavior

**Steps**
1. Turn Wi-Fi off on the phone (keep mobile data on).
2. Stay in the same indoor spot as test 1.
3. Open Mark Attendance (or tap "Recheck location" if already open).

**Expected**
- The quick network fix will likely be coarser (cell-tower based) than on Wi-Fi.
- If that coarse fix is still decisive (clearly inside or outside the 100m radius once its
  own margin of error is accounted for), it resolves without any extra step.
- If it's ambiguous (e.g. you're near the boundary, or accuracy is worse than ~15m and
  the fix doesn't clearly land inside or outside), you should see "Getting a more precise
  location…" while it escalates to GPS.
- It should NOT show "Location request timed out." — that message no longer exists for
  this screen.

**Record if different:** whether you saw "Getting a more precise location…", how long
GPS escalation took, and whether it eventually succeeded or showed "Couldn't get a
precise enough location…". If you have accuracy logging, note the quick fix's accuracy
value — this is the main thing determining which path you hit.

---

## 3. Outside the geofence — message should show a real distance and radius

**Steps**
1. Walk outside the 100m radius — far enough that there's no ambiguity (e.g. 150-200m
   away, or across the street if that's clearly outside).
2. Open Mark Attendance.
3. Read the location status line, and try tapping where "Mark Attendance" would be
   (it should be disabled) to see the disabled-reason text.

**Expected**
- Status line: "You are **[N]**m from the office — check-in needs you within **100**m"
  (N should be roughly your real walking distance, rounded to a whole number — not a
  decimal, not "outside the office geofence" with no number).
- Disabled-button reason: "You are **[N]**m from the office — check-in needs you within
  100m." — wording differs slightly but should also include the real distance.
- The Mark Attendance button stays disabled.

**Record if different:** the exact text shown, whether a number appeared at all, and
whether the number is roughly right for how far you actually walked (large mismatches —
e.g. showing 2000m when you walked 150m — would mean a bad or stale fix was accepted; note
the accuracy value for that reading if you have it).

---

## 4. Location permission denied — message must be the permission one, not "imprecise"

**Steps**
1. In Chrome site settings for the technician app's URL, set Location to "Block" (or deny
   it when the browser prompts, if you haven't granted it before — you may need to clear
   the existing site permission first: Chrome > site info icon > Permissions > Location >
   reset, then reload).
2. Open Mark Attendance.

**Expected**
- Status line / error shows the permission-denied message: "Location access denied.
  Enable location permission for this site in your browser settings, then recheck."
- It must NOT show "Couldn't get a precise enough location… move near a window or step
  outside" (that message is reserved for a coarse-but-successful fix, not a flat
  permission denial) and must NOT show a generic timeout message.
- Re-enabling the permission and tapping "Recheck location" should recover normally.

**Record if different:** the exact message shown instead, and confirm whether re-enabling
permission and tapping "Recheck location" fixes it without a full page reload.
