import { Component, type ErrorInfo, type ReactNode } from "react"
import { TriangleAlert } from "lucide-react"
import { Button } from "@/components/ui/button"
import i18n from "@/lib/i18n"

type ErrorBoundaryProps = { children: ReactNode }
type ErrorBoundaryState = { hasError: boolean }

/**
 * Top-level render-error catch-all (React error boundaries require a class
 * component — there is no hooks equivalent). Mounted once in main.tsx,
 * outside the router, so a crash while navigating doesn't also take out the
 * boundary that's supposed to catch it. Shows a friendly fallback instead of
 * a white screen; the underlying error always goes to console.error so it's
 * still diagnosable from devtools/remote logs.
 *
 * Uses the i18next singleton directly (rather than useTranslation) since
 * class components can't call hooks, and this boundary must keep working
 * even if the error originated inside I18nProvider's own subtree.
 */
export class ErrorBoundary extends Component<ErrorBoundaryProps, ErrorBoundaryState> {
  state: ErrorBoundaryState = { hasError: false }

  static getDerivedStateFromError(): ErrorBoundaryState {
    return { hasError: true }
  }

  componentDidCatch(error: Error, errorInfo: ErrorInfo) {
    console.error("Unhandled render error:", error, errorInfo)
  }

  render() {
    if (this.state.hasError) {
      return (
        <div className="flex min-h-screen flex-col items-center justify-center gap-3 bg-bg px-6 text-center">
          <TriangleAlert className="size-8 text-danger" />
          <p className="text-base font-semibold text-text">{i18n.t("common.errorBoundaryTitle")}</p>
          <p className="max-w-xs text-sm text-text-muted">{i18n.t("common.errorBoundaryBody")}</p>
          <Button type="button" onClick={() => window.location.reload()}>
            {i18n.t("common.reload")}
          </Button>
        </div>
      )
    }
    return this.props.children
  }
}
