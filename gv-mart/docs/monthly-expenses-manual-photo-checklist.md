# Monthly Expenses — manual photo-path checklist

Run this by hand against a real environment once the migrations are applied
there. It covers what could not be exercised from this session (no access to
the Storage HTTP API). Each step lists what to do and what you should see.

Needs: one technician login, one master or operation_admin login, a phone or
a browser with a camera, and one image file over 5MB and one non-image file
(e.g. a `.pdf` or `.txt`) ready to pick from the device.

## 1. Technician uploads from the camera

1. Sign in as a technician.
2. Go to **Expenses** → submit a petrol or maintenance bill.
3. Enter an amount, then use the camera-capture option to take a photo of a
   real bill.
4. Submit.

**Expect:** the submission succeeds, shows "submitted — waiting for
verification," and a new row appears in the technician's own history.

## 2. Technician uploads from the gallery

1. Same screen, same technician.
2. This time pick an existing photo from the gallery/file picker instead of
   the camera.
3. Submit.

**Expect:** same success behaviour as step 1 — both capture paths work
identically.

## 3. Admin opens the photograph from the verification queue

1. Sign in as master or operation_admin.
2. Go to **Expenses → Verification Queue**.
3. Find the claim submitted in step 1 or 2.
4. Click **View bill**.

**Expect:** the photograph opens in a new tab and is clearly the bill just
uploaded. The link should not keep working indefinitely — if you copy the
URL and open it again after roughly an hour, it should no longer load (the
signed URL has expired).

## 4. A file over the size limit is refused

1. As the technician, try to submit a bill again.
2. Pick an image file larger than 5MB.

**Expect:** the upload is refused with a message the technician can act on
(not a raw error code or a blank failure) — something like "file too large."
Nothing should appear in the verification queue for this attempt.

## 5. A non-image file is refused

1. Same screen. Pick a `.pdf`, `.txt`, or any non-image file instead.

**Expect:** the upload is refused before or immediately after picking the
file, with a message indicating only photos are accepted. Nothing should
appear in the verification queue for this attempt.

## 6. A technician cannot open another technician's photograph by guessing its key

This one needs two technician logins (or one technician login plus a way to
inspect the network request, e.g. browser dev tools).

1. As technician A, submit a bill and note the storage path if you can see it
   (dev tools → Network tab → the upload request's path, shaped like
   `<org id>/<technician id>/<random id>.jpg`).
2. Sign in as technician B.
3. Attempt to construct and open that same storage path directly (e.g. by
   editing technician A's path to swap in a path you've seen, or by trying
   technician A's exact path from technician B's session).

**Expect:** access is denied — technician B cannot view technician A's
photograph, whether through the app's own verification screen (which
technician B shouldn't even see, since the queue is admin-only) or by
guessing the path directly. Trying to view another technician's claim
through the technician app at all should likewise show nothing from
technician A.

---

Report each step as pass/fail with whatever you actually saw, especially for
steps 4-6 — those are the ones most likely to reveal something this session
could not check.

## Known limitation: the petrol reference figure is unreviewed data

The verification queue shows the admin a "reference" figure (km × the
technician's rate) next to every petrol claim, so the admin has something to
check the claim against. That kilometre figure comes from
`technician_km_log`, which **anyone with insert rights — including the
technician themself — can write to, with no approval or verification step at
all** (append-only, no status column, no review gate). The admin's sanity
check when deciding what to verify a petrol claim at therefore rests on
self-reported, never-verified input from the same technician submitting the
claim. The verify screen's label now says this explicitly ("from
self-reported km, not verified"); this is a design gap worth deciding on
later (e.g. an odometer photo, or an admin-only km entry path), not something
fixed here.
