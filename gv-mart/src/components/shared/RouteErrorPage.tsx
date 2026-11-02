import { useTranslation } from "react-i18next"
import { useRouteError } from "react-router-dom"
import { TriangleAlert } from "lucide-react"
import { Button } from "@/components/ui/button"

/**
 * Stale-chunk fix, part 2 -- react-router's own `errorElement` boundary, separate from (and
 * nearer the failure than) the global ErrorBoundary in main.tsx. A lazy route chunk that fails
 * to load (stale deploy, offline, genuine 404) throws during that route's render; react-router
 * catches it here instead of taking down the whole app shell. `vite:preloadError`'s one-time
 * auto-reload (main.tsx) handles the common case silently before the user ever sees this --
 * this is the fallback for whatever that doesn't catch (the guard already fired once this
 * session and the problem persists, or a non-preload error). Logs via console.error so it's
 * still diagnosable from devtools/remote logs, same as the global ErrorBoundary.
 */
export function RouteErrorPage() {
  const { t } = useTranslation()
  const error = useRouteError()
  console.error("Route error:", error)
  return (
    <div className="flex min-h-screen flex-col items-center justify-center gap-3 bg-bg px-6 text-center">
      <TriangleAlert className="size-8 text-danger" />
      <p className="text-base font-semibold text-text">{t("common.errorBoundaryTitle")}</p>
      <p className="max-w-xs text-sm text-text-muted">{t("common.errorBoundaryBody")}</p>
      <Button type="button" onClick={() => window.location.reload()}>
        {t("common.reload")}
      </Button>
    </div>
  )
}
