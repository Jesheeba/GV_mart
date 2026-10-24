import { useEffect } from "react"
import { useTranslation } from "react-i18next"
import { useBlocker } from "react-router-dom"
import { Button } from "@/components/ui/button"
import { Dialog, DialogContent, DialogDescription, DialogTitle } from "@/components/ui/dialog"

/**
 * The actual place a "silent unsaved edit" bug lives: not the lack of a
 * visible Save button (that's discoverability), but that leaving the page —
 * via in-app navigation (sidebar click, back button) or a tab close/reload —
 * drops whatever wasn't explicitly saved, with nothing to stop it. Two
 * separate browser mechanisms, both needed:
 *   - SPA navigation (clicking elsewhere in the app) never touches the
 *     browser's own unload machinery, so `beforeunload` alone never fires
 *     for it — only a router-level blocker catches this one.
 *   - Closing the tab or hitting refresh never runs React Router's
 *     navigation lifecycle, so only `beforeunload` catches that one.
 * `when` should be the same "is anything unsaved" boolean already driving
 * a page's own unsaved-changes indicator.
 */
export function UnsavedChangesGuard({ when }: { when: boolean }) {
  const { t } = useTranslation()

  const blocker = useBlocker(({ currentLocation, nextLocation }) => when && currentLocation.pathname !== nextLocation.pathname)

  useEffect(() => {
    if (!when) return
    function handler(e: BeforeUnloadEvent) {
      // Chrome (and most browsers, per spec) ignore this string and show
      // their own fixed, non-localizable dialog instead — setting it is
      // still correct practice for the handful of engines that don't.
      e.preventDefault()
      e.returnValue = t("settings.beforeUnloadWarning")
      return e.returnValue
    }
    window.addEventListener("beforeunload", handler)
    return () => window.removeEventListener("beforeunload", handler)
  }, [when, t])

  if (blocker.state !== "blocked") return null

  return (
    <Dialog open onOpenChange={(open) => !open && blocker.reset()}>
      <DialogContent className="max-w-sm">
        <DialogTitle>{t("settings.leaveWithoutSavingTitle")}</DialogTitle>
        <DialogDescription>{t("settings.leaveWithoutSavingBody")}</DialogDescription>
        <div className="flex justify-end gap-1.5">
          <Button variant="ghost" onClick={() => blocker.reset()}>
            {t("settings.stayOnPage")}
          </Button>
          <Button variant="destructive" onClick={() => blocker.proceed()}>
            {t("settings.leaveAnyway")}
          </Button>
        </div>
      </DialogContent>
    </Dialog>
  )
}
