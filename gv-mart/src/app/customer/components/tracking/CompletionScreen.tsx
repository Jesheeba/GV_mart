import { useTranslation } from "react-i18next"
import { CheckCircle2, Wrench } from "lucide-react"
import { Button } from "@/components/ui/button"

/** Service Completed hero (spec: thank the customer, offer to book again).
 * Deliberately just the celebratory header + CTA — the existing rating and
 * invoice cards on CustomerBookingDetailPage already handle those (rating
 * gained a customer-submit form when none exists yet; invoice gained a
 * print button) rather than duplicating them here under a second card. */
export function CompletionScreen({ technicianName, onBookAgain }: { technicianName: string | null; onBookAgain: () => void }) {
  const { t } = useTranslation()

  return (
    <div className="flex flex-col items-center gap-2 rounded-card bg-gradient-to-br from-success/15 to-success/5 px-5 py-8 text-center">
      <span className="animate-in zoom-in-50 flex size-16 items-center justify-center rounded-full bg-success/20 text-success duration-500">
        <CheckCircle2 className="size-9" />
      </span>
      <h1 className="text-lg font-extrabold text-text">{t("customerApp.tracking.completionTitle")}</h1>
      <p className="text-sm text-text-muted">
        {technicianName ? t("customerApp.tracking.completionBodyNamed", { name: technicianName }) : t("customerApp.tracking.completionBody")}
      </p>
      <Button type="button" variant="outline" className="mt-2 print:hidden" onClick={onBookAgain}>
        <Wrench className="size-4" />
        {t("customerApp.tracking.bookAnother")}
      </Button>
    </div>
  )
}
