import { StrictMode, Suspense } from "react"
import { createRoot } from "react-dom/client"
import { QueryClientProvider } from "@tanstack/react-query"
import { RouterProvider } from "react-router-dom"
import { Capacitor } from "@capacitor/core"
import { App as CapacitorApp } from "@capacitor/app"
import { registerSW } from "virtual:pwa-register"
import { checkForOtaUpdate, notifyOtaAppReady } from "@/lib/ota/otaManager"
import { shouldReloadOnPreloadError } from "@/lib/staleChunkReload"
import { StoreUpdateGate } from "@/lib/ota/storeUpdateGate"
import { queryClient } from "@/lib/queryClient"
import { ThemeProvider } from "@/lib/theme/ThemeProvider"
import { I18nProvider } from "@/lib/i18n/I18nProvider"
import { AuthProvider } from "@/hooks/useAuth"
import { ErrorBoundary } from "@/components/shared/ErrorBoundary"
import { ToastProvider } from "@/components/ui/toast"
import { router } from "./router"
import "./index.css"

// Stale-chunk fix (web only -- the native app's assets are bundled, not fetched over the
// network, so this can't happen there). Vite's lazy-loaded route chunks are fetched by hashed
// filename; once a new deploy replaces those files, a browser tab left open on the OLD
// index.html still tries to import an asset hash that no longer exists, and Vite's own runtime
// fires this `vite:preloadError` window event instead of letting the raw network/syntax error
// surface. A single automatic reload almost always fixes it (the reload fetches the CURRENT
// index.html, which references the current, actually-present chunk hashes) -- guarded by
// sessionStorage so a genuinely broken deploy reloads once, then falls through to the normal
// error UI (the router's errorElement / the top-level ErrorBoundary) instead of looping forever.
if (!Capacitor.isNativePlatform()) {
  window.addEventListener("vite:preloadError", (event) => {
    event.preventDefault()
    if (shouldReloadOnPreloadError(sessionStorage)) window.location.reload()
  })
}

// Skipped inside the native app — Capacitor's WebView already serves local
// static assets directly, and a competing Workbox SW risks stale-asset bugs.
if (!Capacitor.isNativePlatform()) {
  registerSW({ immediate: true })
} else {
  // Must run before any network request, per @capgo/capacitor-updater's
  // own docs — it only confirms the JS bundle itself loaded, nothing more.
  // Not calling this within appReadyTimeout triggers an automatic rollback
  // to the last-known-good bundle.
  void notifyOtaAppReady()
  // Fire-and-forget: checks the OTA manifest, verifies its signature, and
  // (if newer) downloads + queues the update for the next background/
  // restart. Never blocks rendering and never interrupts an active visit.
  void checkForOtaUpdate()
  CapacitorApp.addListener("resume", () => {
    void checkForOtaUpdate()
  })
}

createRoot(document.getElementById("root")!).render(
  <StrictMode>
    {/* Outside everything else (including the router) so a render error
        anywhere — including during navigation — still hits this boundary
        instead of producing a white screen. */}
    <ErrorBoundary>
      <Suspense fallback={null}>
        <I18nProvider>
          <ThemeProvider>
            {/* Native-only: blocks the app when the installed native shell is too
                old to safely run the latest OTA bundle (see src/lib/ota). On web
                it always renders children, since checkForOtaUpdate never runs there. */}
            <StoreUpdateGate>
              <QueryClientProvider client={queryClient}>
                <AuthProvider>
                  <ToastProvider>
                    <RouterProvider router={router} />
                  </ToastProvider>
                </AuthProvider>
              </QueryClientProvider>
            </StoreUpdateGate>
          </ThemeProvider>
        </I18nProvider>
      </Suspense>
    </ErrorBoundary>
  </StrictMode>
)
