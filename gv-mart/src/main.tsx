import { StrictMode, Suspense } from "react"
import { createRoot } from "react-dom/client"
import { QueryClientProvider } from "@tanstack/react-query"
import { RouterProvider } from "react-router-dom"
import { Capacitor } from "@capacitor/core"
import { registerSW } from "virtual:pwa-register"
import { queryClient } from "@/lib/queryClient"
import { ThemeProvider } from "@/lib/theme/ThemeProvider"
import { I18nProvider } from "@/lib/i18n/I18nProvider"
import { AuthProvider } from "@/hooks/useAuth"
import { ErrorBoundary } from "@/components/shared/ErrorBoundary"
import { ToastProvider } from "@/components/ui/toast"
import { router } from "./router"
import "./index.css"

// Skipped inside the native app — Capacitor's WebView already serves local
// static assets directly, and a competing Workbox SW risks stale-asset bugs.
if (!Capacitor.isNativePlatform()) {
  registerSW({ immediate: true })
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
            <QueryClientProvider client={queryClient}>
              <AuthProvider>
                <ToastProvider>
                  <RouterProvider router={router} />
                </ToastProvider>
              </AuthProvider>
            </QueryClientProvider>
          </ThemeProvider>
        </I18nProvider>
      </Suspense>
    </ErrorBoundary>
  </StrictMode>
)
