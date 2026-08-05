import { useEffect } from "react"
import { useTranslation } from "react-i18next"
import { CheckCircle2 } from "lucide-react"

/** Brief full-screen celebration shown once on the transition into
 * "arrived_working" (see useLiveTracking's `arrivalSignal`) — CSS-only
 * (tailwindcss-animate utilities already used elsewhere, e.g. dialog.tsx),
 * no animation library. Auto-dismisses; tap-to-dismiss early. */
export function ArrivalCelebration({ visible, onClose, technicianName }: { visible: boolean; onClose: () => void; technicianName?: string }) {
  const { t } = useTranslation()

  useEffect(() => {
    if (!visible) return
    const id = window.setTimeout(onClose, 2500)
    return () => window.clearTimeout(id)
  }, [visible, onClose])

  if (!visible) return null

  return (
    <div
      role="status"
      onClick={onClose}
      className="animate-in fade-in-0 fixed inset-0 z-50 flex flex-col items-center justify-center gap-4 bg-ink/85 px-6 text-center backdrop-blur-sm duration-200"
    >
      <span className="animate-in zoom-in-50 flex size-20 items-center justify-center rounded-full bg-success/20 text-success duration-500">
        <CheckCircle2 className="size-12" />
      </span>
      <p className="text-xl font-bold text-white">{t("customerApp.tracking.arrivedTitle")}</p>
      <p className="text-sm text-white/80">
        {technicianName ? t("customerApp.tracking.arrivedBodyNamed", { name: technicianName }) : t("customerApp.tracking.arrivedBody")}
      </p>
    </div>
  )
}
