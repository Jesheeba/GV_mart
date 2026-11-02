export interface KeyValueStore {
  getItem(key: string): string | null
  setItem(key: string, value: string): void
}

const STALE_CHUNK_RELOAD_KEY = "gv-mart-stale-chunk-reloaded"

/**
 * Stale-chunk fix, part 1. True only the FIRST time this is called against a given storage
 * (sessionStorage in real use) -- marks itself so a second call in the same session returns
 * false, so a `vite:preloadError` that persists after the first reload falls through to the
 * normal error UI (the router's errorElement / the top-level ErrorBoundary) instead of
 * reloading forever.
 */
export function shouldReloadOnPreloadError(storage: KeyValueStore): boolean {
  if (storage.getItem(STALE_CHUNK_RELOAD_KEY)) return false
  storage.setItem(STALE_CHUNK_RELOAD_KEY, "1")
  return true
}
