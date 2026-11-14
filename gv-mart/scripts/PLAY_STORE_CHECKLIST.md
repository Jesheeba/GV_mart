# Play Store submission checklist

One-time native submission. After this first release, almost everything
(UI, logic, screens) ships via OTA (`scripts/OTA_PUBLISH.md`) with no further
Play Console review — only changes under `android/` (new permission, new
native plugin, SDK/Gradle bump) ever require repeating steps 3–7 below.

Publishing from **Sirah Digital's** existing Play Console organization
account (owner decision, 2026-11-12) — the public "Offered by" byline will
show Sirah Digital, while the app content (description, privacy policy,
Data Safety) describes GV Mart's business.

## 1. Already done — verified in repo

- [x] Release keystore configured: `android/app/build.gradle` reads
      `_local_only/secrets/android/keystore.properties` (gitignored, outside
      the repo tree committed to GitHub).
- [x] `targetSdk`/`compileSdk` 36, `minSdk` 24 — meets Play's 2025 target-API
      policy (34+).
- [x] `capacitor.config.ts` has no dev `server.url` override — ships the
      bundled `dist/`, not a localhost/dev server.
- [x] App icons present for all densities + adaptive icon
      (`android/app/src/main/res/mipmap-*`), updated to GV Mart's real logo.
- [x] `RECORD_AUDIO` permission is genuinely used (technician voice notes,
      `src/app/technician/components/VoiceNoteRecorder.tsx`) — keep it.
- [x] Privacy policy page built: `/privacy-policy`
      (`src/app/legal/PrivacyPolicyPage.tsx`), public route, no login
      required. Contact details filled in with GV Mart's real business
      name, address, phone, and email.

## 2. Account registration (Sirah Digital, one-time)
- D-U-N-S number: already held by Sirah Digital.
- Registered business address, legal name, authorized representative ID:
  Sirah Digital's own details, entered during Play Console account setup.
- Trader status declaration: complete this from the Play Console dashboard
  banner before anything else if not already done.

## 3. Build the release AAB

```
cd gv-mart
npx cap sync android
cd android
./gradlew bundleRelease
```

Output: `android/app/build/outputs/bundle/release/app-release.aab`.
Bump `versionCode` in `android/app/build.gradle` before every new upload —
Play Console rejects a version code that's already been used, even from a
failed/discarded release.

## 4. Play Console — create the app

1. [Play Console](https://play.google.com/console) → Create app.
2. App name: `GV Mart`. Default language, app/game type, free/paid.
3. Accept the declarations (Developer Program Policies, US export laws,
   content guidelines).
4. Package name: `com.gvmart.app` — permanent once set, matches
   `applicationId` in `android/app/build.gradle`.

## 5. Store listing

Draft copy, contact details, and the Data Safety answers table are in
`scripts/PLAY_STORE_LISTING.md` — paste that content in directly. Still
needed and not generated: real screenshots and a 1024×500 feature graphic.
Privacy policy URL: `https://gv-mart.vercel.app/privacy-policy` (confirm
this matches the production domain — see note in `OTA_PUBLISH.md`).

## 6. App content section

- **Privacy policy**: paste the URL above.
- **Data safety form** — declare per the data this app actually collects:
  | Data type | Collected? | Shared? | Purpose |
  |---|---|---|---|
  | Name, phone, email | Yes | No | Account management, app functionality |
  | Precise location | Yes (technicians only) | No | App functionality (job routing) |
  | Audio (voice notes) | Yes (technicians only) | No | App functionality |
  | Customer/service records (addresses, purchase history) | Yes | No | App functionality |
  All data: encrypted in transit (HTTPS/Supabase), user can request deletion
  (see privacy policy "Contact us").
- **Government apps**: No (unless this changes).
- **Ads**: No ads in this app.
- **Content rating questionnaire**: answer per actual app content — no
  user-generated public content, no violence/gambling — expect a "3+"/"PEGI
  3"-equivalent rating.
- **Target audience**: not designed for children; standard age range.
- **Data deletion**: either implement an in-app "delete my account" request
  flow, or at minimum make sure the privacy policy's contact channel can
  fulfill deletion requests (current page does this).

## 7. Release

1. Testing track first (Internal testing) with the AAB from step 3 —
   install on a real device, sanity-check login, location permission
   prompt (including the native "Turn on device location?" dialog added
   via `cordova-plugin-request-location-accuracy`), voice note recording,
   and app icon/splash branding.
2. Promote to Production once the test track looks good.
3. First review typically takes a few hours to a few days for a new app.

## 8. After approval

- Record the live Play Store listing URL in `build-docs/MEMORY.md`.
- From here on, ship feature/UI/logic changes via
  `node scripts/ota-publish.mjs --channel production ...` — no Play Console
  trip needed unless `android/` changes.
