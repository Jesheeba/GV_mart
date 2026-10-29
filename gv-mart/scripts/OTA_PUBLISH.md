# Publishing an OTA update

One command, run from `gv-mart/`:

```
node scripts/ota-publish.mjs --channel technician-test --build 3 --min-native-build 1
```

- `--channel` — `technician-test` or `production`. Always ship to `technician-test` first, confirm it on the owner's phone, then re-run with `--channel production` using the same `--build` number (or a higher one).
- `--build` — a plain integer, strictly increasing **within that channel**. This is what the app compares to decide "is there something new" — bump it every release.
- `--min-native-build` — the lowest native `versionCode` (Play Store build) that can safely run this JS bundle. Leave it at the current Play build's versionCode unless this release needs a native change that isn't in anyone's hands yet (it never should, by construction — an OTA release never touches `android/`).
- `--frozen` — add this to publish a manifest that tells every device on that channel to stop checking for a moment (kill switch), without removing the previous working bundle.
- `OTA_SITE_ORIGIN=https://<your-vercel-domain>` — set this env var (or edit `public/ota/<channel>/manifest.json`'s `url` field by hand afterwards) so the manifest points at the real deployed domain instead of the placeholder.

The script builds the web app, zips `dist/`, computes its sha256, signs the manifest with the private key in `_local_only/secrets/ota/`, and writes both files to `public/ota/<channel>/`.

**To actually ship it:** commit `public/ota/<channel>/manifest.json` and `bundle.zip`, then push to `main`. Vercel's normal deploy serves the new files — no Play Store build, no app restart required from the owner. Installed apps pick it up next time they're opened or resumed, and it only takes effect the *following* app launch/background (never mid-visit).

## Rollback

To force every device on a channel back to a known-good version, re-run the script with the *same* `--build` number as the last good release (or edit `manifest.json`'s `url`/`checksum`/`buildNumber` by hand to point at the previous `bundle.zip`), then push. Devices that already applied the bad build will also self-heal automatically: if the bad bundle's JS never calls `notifyAppReady()` within 10 seconds of launch, `@capgo/capacitor-updater` reverts to the last-known-good bundle on its own.

## What this can never ship

Anything under `android/` — new native plugins, `AndroidManifest.xml` permission changes, Gradle/SDK version bumps. Those need a new signed AAB through Play Console (see `PLAY_STORE_CHECKLIST.md`).
