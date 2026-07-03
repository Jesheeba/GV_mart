import { StrictMode, Suspense } from "react"
import { createRoot } from "react-dom/client"
import { QueryClientProvider } from "@tanstack/react-query"
import { RouterProvider } from "react-router-dom"
import { queryClient } from "@/lib/queryClient"
import { ThemeProvider } from "@/lib/theme/ThemeProvider"
import { I18nProvider } from "@/lib/i18n/I18nProvider"
import { AuthProvider } from "@/hooks/useAuth"
import { router } from "./router"
import "./index.css"

createRoot(document.getElementById("root")!).render(
  <StrictMode>
    <Suspense fallback={null}>
      <I18nProvider>
        <ThemeProvider>
          <QueryClientProvider client={queryClient}>
            <AuthProvider>
              <RouterProvider router={router} />
            </AuthProvider>
          </QueryClientProvider>
        </ThemeProvider>
      </I18nProvider>
    </Suspense>
  </StrictMode>
)
