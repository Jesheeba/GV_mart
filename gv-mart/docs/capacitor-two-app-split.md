# Capacitor two-app split — decision record

**Status:** parked, not started. Recorded 2026-08-19 so this doesn't get re-derived later.

## Current state

- One Capacitor app, one app id: `com.gvmart.app` (`capacitor.config.ts`,
  `android/app/build.gradle` `namespace`/`applicationId`,
  `ios/App/App.xcodeproj/project.pbxproj` `PRODUCT_BUNDLE_IDENTIFIER` ×2).
- One shared `android/` and one shared `ios/` native project tree, both
  generated from and synced against a single web build.
- That single web build serves all three role shells (admin, technician,
  customer) behind one router — same bundle regardless of who's logging in.
- One `AndroidManifest.xml` / one `Info.plist`, so one permission set for
  the whole app. `ACCESS_FINE_LOCATION`/`ACCESS_COARSE_LOCATION` are already
  declared (from `@capacitor/geolocation`, used by technician
  attendance/tracking).
- Native Google OAuth (`src/services/auth.ts`, committed `219e272`) uses a
  `gvmart://auth-callback` deep link — a literal string in
  `AndroidManifest.xml`'s intent-filter and `Info.plist`'s
  `CFBundleURLSchemes`, independent of the app id.

## The original plan

Two builds — `com.gvmart.app.tech` and `com.gvmart.app.customer` — as
separate Play Store listings, because one app declaring both technician
location/camera permissions and customer-facing permissions together risks
rejection at Google Play Data Safety review.

## What a split actually requires

The app id itself is cosmetic — renaming it is the cheap part. What a real
split needs:

1. **Two `capacitor.config.ts`** (or one parameterized by a build-time env
   var), one `appId` each.
2. **Two native project trees**, generated fresh via `cap add android` /
   `cap add ios` into separate folders — Capacitor's own tooling (`cap
   sync`, `@capacitor/assets`) assumes one target directory per app; Gradle
   product flavors inside a single tree are possible but fight that
   tooling rather than working with it.
3. **Distinct deep-link schemes** — e.g. `gvmart-tech://` /
   `gvmart-customer://` instead of both sharing `gvmart://`. Not required
   today (only one app exists), but cheap to decide now and expensive to
   discover as a collision later if both apps ever end up installed on the
   same device.
4. **Trimmed permissions per variant, verified in the MERGED manifest, not
   the source one.** (Correction, 2026-08-19: Capacitor plugins inject
   permissions transitively during Android's manifest merge — if
   `@capacitor/geolocation` is installed, the customer variant can still
   end up with `ACCESS_FINE_LOCATION` in its final APK even after removing
   the `<uses-permission>` line from the source `AndroidManifest.xml`.) Any
   future verification that a variant's permission set is actually clean
   must inspect `android/app/build/intermediates/merged_manifests/`, not
   the source file, and equivalently check the actual archived
   `Info.plist`/entitlements for iOS rather than the source one.
5. **Variant-gated route imports — a separate web build per variant, not
   optional.** (Correction, 2026-08-19: originally scoped as
   "belt-and-suspenders, not strictly required." That's wrong. A customer
   AAB that still contains technician route code invites exactly the
   review question the split exists to avoid, and ships code to devices
   that have no legitimate reason to run it.) This means the customer
   build's web bundle must not import technician-only routes/components at
   build time (not just gate them behind a runtime role check) — a build
   concern, not just a native-manifest one.

## Not done

None of the above has been implemented. App id is still singular
(`com.gvmart.app`), one manifest, one web bundle, one native tree per
platform. This file exists so the shape of the work is findable next time,
not so it looks started.
