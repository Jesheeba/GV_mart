# Publishing an OTA update

One command, run from `gv-mart/`:

```
node scripts/ota-publish.mjs --channel technician-test --build 3 --min-native-build 1
```

- `--channel` — `technician-test` or `production`. Always ship to `technician-test` first, confirm it on the owner's phone, then re-run with `--channel production` using the same `--build` number (or a higher one).
- `--build` — a plain integer, strictly increasing **within that channel**. This is what the app compares to decide "is there something new" — bump it every release.
- `--min-native-build` — the lowest native `versionCode` (Play Store build) that can safely run this JS bundle. Leave it at the current Play build's versionCode unless this release needs a native change that isn't in anyone's hands yet (it never should, by construction — an OTA release never touches `android/`).
- `--frozen` — add this to publish a manifest that tells every device on that channel to stop checking for a moment (kill switch), without removing the previous working bundle.
- `OTA_SITE_ORIGIN=https://<your-vercel-domain>` — set this env var (or edit `public/ota/<channel>/manifest.json`'s `url` field by hand afterwards) so the manifest points at the real deployed domain instead of the placeholder. **The real production domain is `https://gv-mart.vercel.app`** — confirmed live (`curl -sI https://gv-mart.vercel.app` → 200, page title "GV Mart Admin") and matches the domain already named in `supabase/functions/_shared/staff-cors.ts`'s own example comment. It's not set anywhere in this repo's own config (Vercel's GitHub integration manages the alias outside the codebase), so if this ever needs re-confirming: Vercel dashboard → the `gv-mart` project → Settings → Domains lists the authoritative production alias, or `https://vercel.com/jesheeba-fathimas-projects/gv-mart` → the latest Production deployment → "Visit".

The script builds the web app, zips `dist/`, computes its sha256, signs the manifest with the private key in `_local_only/secrets/ota/`, and writes both files to `public/ota/<channel>/`.

**To actually ship it:** commit `public/ota/<channel>/manifest.json` and `bundle.zip`, then push to `main`. Vercel's normal deploy serves the new files — no Play Store build, no app restart required from the owner. Installed apps pick it up next time they're opened or resumed, and it only takes effect the *following* app launch/background (never mid-visit).

## Bundle retention

Each publish keeps only the **2 most recent** bundle zips per channel (`bundle-<N>.zip`) — older ones are deleted automatically by the script, so the repo doesn't grow by a full bundle on every release. This is also why rollback (below) never needs a rebuild: the previous build's zip is still sitting right there in `public/ota/<channel>/`.

## Kill switch and rollback — both are just "edit the manifest + push"

There is no separate rollback tooling. Both of these are a hand-edit of `public/ota/<channel>/manifest.json` followed by a normal `git push` to `main`:

- **Kill switch** (stop everyone on a channel from checking at all, without touching anything else): set `"frozen": true` in that channel's `manifest.json`, commit, push. No rebuild needed.
- **Rollback** (force everyone back onto the previous build): edit `manifest.json`'s `url`, `checksum`, and `buildNumber` to point at the previous `bundle-<N-1>.zip` (still present thanks to the 2-bundle retention above — you can read its correct checksum straight out of this channel's git history, the prior commit's `manifest.json`), **re-sign it** (the signature covers those exact fields — you can't hand-edit a signed manifest and leave the old signature in place, the app will reject it). Easiest way to re-sign without a full rebuild: run `node scripts/ota-publish.mjs --channel <channel> --build <N-1> --min-native-build <...>` again — it rebuilds and re-publishes that same version fresh, which is equivalent and always has a valid signature, at the cost of a rebuild.

**Before the first real production push, prove this works and time it**, per the owner's 2026-10-29 instruction:
1. Push a `"frozen": true` edit to `technician-test`'s manifest to `main`.
2. Starting from the push, repeatedly `curl -s https://gv-mart.vercel.app/ota/technician-test/manifest.json` (or open it in a browser with cache disabled) and note the wall-clock time until the response shows `"frozen": true`. That's your real kill-switch latency on this Vercel project — Vercel's own deploy step plus whatever CDN caching applies to a plain static JSON file (static assets can have their own cache-control; if the measured latency is uncomfortably long, add a `Cache-Control: no-store` rewrite/header for `/ota/**` in `vercel.json` and re-measure).
3. Record the measured number here or in the OTA release report before flipping `frozen` back to `false` and shipping the first real production bundle.

This step could not be completed in this pass — this environment can read the live site over plain HTTPS (confirmed `https://gv-mart.vercel.app` is real and serving the app, via the public GitHub Deployments API), but has no Vercel CLI/API credentials to actually push a change and watch it deploy end-to-end from here. It's the one concrete action item for whoever has deploy access before the first production OTA push.

## First production OTA push — exact commands

Run from `gv-mart/` on a clean checkout of `main`, after the real signed Play build (`PLAY_STORE_CHECKLIST.md`) is out and this OTA system has already been proven on `technician-test`:

```
git pull origin main
OTA_SITE_ORIGIN=https://gv-mart.vercel.app node scripts/ota-publish.mjs --channel production --build 1 --min-native-build 1
git add public/ota/production
git commit -m "ota(production): first production bundle"
git push origin main
```

- `--build 1` here means "first production-channel release," independent of whatever build number `technician-test` is already on — each channel's build counter is its own, per `ota-publish.mjs`.
- `--min-native-build 1` matches the Play build's `versionCode` from `android/app/build.gradle` at the time this is run — bump it only if a later native release changes what the JS bundle needs.
- After the push, confirm it actually served: `curl -s https://gv-mart.vercel.app/ota/production/manifest.json` should return the manifest you just wrote (check `buildNumber` and `checksum` match this run's console output).
- Every production release after the first is the same three commands with `--build` incremented.

## What this can never ship

Anything under `android/` — new native plugins, `AndroidManifest.xml` permission changes, Gradle/SDK version bumps. Those need a new signed AAB through Play Console (see `PLAY_STORE_CHECKLIST.md`).
