import { useEffect } from "react"

type RecheckTargets = {
  document: Pick<Document, "visibilityState" | "addEventListener" | "removeEventListener">
  window: Pick<Window, "addEventListener" | "removeEventListener">
  navigator: Pick<Navigator, "permissions">
}

/**
 * The pure subscribe/unsubscribe core of useGeoPermissionRecheck below, with
 * document/window/navigator passed in instead of read from the globals --
 * this repo's vitest environment has no DOM (see router.test.ts's own note
 * on why), so this is what src/hooks/useGeoPermissionRecheck.test.ts
 * exercises directly, with plain EventTarget-based fakes instead of jsdom.
 *
 * Re-runs `recheck` when the tab/app regains visibility or focus, or when
 * the browser's own geolocation permission state changes.
 *
 * Fixes the exact gap that left the technician app's "Turn on location"
 * banner stuck after granting permission mid-session: browsers (confirmed
 * for Chrome) don't resume a dead `watchPosition`/retry a failed
 * `getCurrentPosition` on their own once the user changes the site's
 * permission via the padlock/site-settings UI -- nothing was watching for
 * that change, so the stale error sat in React state forever.
 *
 * `navigator.permissions.query({name:"geolocation"})` isn't supported
 * everywhere (notably older Safari); this degrades silently to
 * visibility/focus alone when it isn't, since those two already cover the
 * common real-world case (grant permission in Chrome's UI, which backgrounds
 * or blurs the page, then return to it).
 */
export function subscribeGeoRecheck(targets: RecheckTargets, recheck: () => void): () => void {
  function onVisibilityChange() {
    if (targets.document.visibilityState === "visible") recheck()
  }
  targets.document.addEventListener("visibilitychange", onVisibilityChange)
  targets.window.addEventListener("focus", recheck)

  let permissionStatus: PermissionStatus | null = null
  let cancelled = false
  if (targets.navigator.permissions?.query) {
    targets.navigator.permissions
      .query({ name: "geolocation" as PermissionName })
      .then((status) => {
        if (cancelled) return
        permissionStatus = status
        status.addEventListener("change", recheck)
      })
      .catch(() => {
        // Permissions API not supported for "geolocation" on this browser -- visibility/focus still cover it.
      })
  }

  return () => {
    cancelled = true
    targets.document.removeEventListener("visibilitychange", onVisibilityChange)
    targets.window.removeEventListener("focus", recheck)
    permissionStatus?.removeEventListener("change", recheck)
  }
}

/**
 * Re-runs `recheck` only while `active` is true, so a healthy watch/position
 * isn't needlessly re-requested on every tab switch. See subscribeGeoRecheck
 * above for what this actually listens to and why.
 */
export function useGeoPermissionRecheck(active: boolean, recheck: () => void) {
  useEffect(() => {
    if (!active) return
    if (typeof document === "undefined" || typeof window === "undefined" || typeof navigator === "undefined") return
    return subscribeGeoRecheck({ document, window, navigator }, recheck)
  }, [active, recheck])
}
