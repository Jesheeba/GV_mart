import { useState } from "react"
import { useTranslation } from "react-i18next"
import { useNavigate, useSearchParams } from "react-router-dom"
import { ArrowLeft, Check, CheckCircle2, Loader2 } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Card } from "@/components/ui/card"
import { DatePicker } from "@/components/ui/date-picker"
import { Label } from "@/components/ui/label"
import { FullPageError, FullPageLoader } from "@/components/shared/FullPageLoader"
import { useAppointmentSlots, useMyCustomerId, useRequestCallback } from "@/hooks/useCustomerApp"

/**
 * Product Enquiry rebuild (2026-08-04), Phase 4 — "Request a Callback."
 * Reuses appointment_slots (already admin-configurable, customer-readable)
 * for the date+slot mechanics, same as service booking — this is
 * genuinely new only in that it creates a sales lead + lead_activities
 * note (request_callback RPC) instead of a service_tickets/appointments
 * row (that would mean "a technician visit is scheduled," which a sales
 * callback is not).
 */
export function CustomerRequestCallbackPage() {
  const { t } = useTranslation()
  const navigate = useNavigate()
  const [searchParams] = useSearchParams()
  const productId = searchParams.get("productId") ?? undefined
  const { orgId, isLoading: loadingId } = useMyCustomerId()
  const { data: slots, isLoading, isError, refetch } = useAppointmentSlots(orgId)
  const requestCallbackMut = useRequestCallback()

  const todayStr = new Date().toISOString().slice(0, 10)
  const [scheduledDate, setScheduledDate] = useState(todayStr)
  const [slotId, setSlotId] = useState<string | null>(null)
  const [note, setNote] = useState("")

  if (loadingId || isLoading) return <FullPageLoader label={t("common.loading")} />
  if (isError) {
    return <FullPageError message={t("customerApp.productEnquiry.callback.loadError")} onRetry={() => refetch()} retryLabel={t("common.retry")} />
  }

  if (requestCallbackMut.isSuccess) {
    return (
      <div className="flex min-h-[70vh] items-center justify-center pt-2">
        <Card className="max-w-md items-center gap-3 py-8 text-center lg:px-5">
          <span className="flex size-12 items-center justify-center rounded-full bg-success/15 text-success">
            <CheckCircle2 className="size-6" />
          </span>
          <h1 className="px-1 text-lg font-bold text-text">{t("customerApp.productEnquiry.callback.submittedTitle")}</h1>
          <p className="px-1 text-sm text-text-muted">{t("customerApp.productEnquiry.callback.submittedBody")}</p>
          <Button onClick={() => navigate("/customer")}>{t("customerApp.productEnquiry.backHome")}</Button>
        </Card>
      </div>
    )
  }

  const activeSlots = slots ?? []

  return (
    <div className="space-y-4 pb-4 pt-2">
      <div className="flex items-center justify-between">
        <button type="button" onClick={() => navigate(-1)} className="flex items-center gap-1.5 text-sm font-medium text-text-muted">
          <ArrowLeft className="size-4" />
          {t("customerApp.productEnquiry.close")}
        </button>
      </div>
      <h1 className="text-xl font-bold text-text">{t("customerApp.productEnquiry.callback.title")}</h1>
      <p className="text-sm text-text-muted">{t("customerApp.productEnquiry.callback.subtitle")}</p>

      <Card className="gap-3 lg:px-5">
        <div className="space-y-1">
          <Label>{t("customerApp.productEnquiry.callback.dateLabel")}</Label>
          <DatePicker value={scheduledDate} onChange={setScheduledDate} min={todayStr} />
        </div>

        <div className="space-y-1">
          <Label>{t("customerApp.productEnquiry.callback.slotLabel")}</Label>
          {activeSlots.length === 0 ? (
            <p className="rounded-xl border border-dashed border-border px-3 py-2.5 text-xs text-text-muted">{t("customerApp.productEnquiry.callback.noSlotsAvailable")}</p>
          ) : (
            <div className="space-y-1.5">
              {activeSlots.map((slot) => {
                const active = slotId === slot.id
                return (
                  <button
                    key={slot.id}
                    type="button"
                    onClick={() => setSlotId(slot.id)}
                    className={`flex w-full items-center justify-between rounded-xl border px-3.5 py-2.5 text-left text-sm transition-colors ${
                      active ? "border-accent bg-accent-soft" : "border-border"
                    }`}
                  >
                    <span className="font-medium text-text">{slot.name}</span>
                    <span className="flex items-center gap-1.5 text-xs text-text-muted">
                      {slot.start_time.slice(0, 5)} – {slot.end_time.slice(0, 5)}
                      {active ? <Check className="size-3.5 text-accent" /> : null}
                    </span>
                  </button>
                )
              })}
            </div>
          )}
        </div>

        <div className="space-y-1">
          <Label>{t("customerApp.productEnquiry.callback.noteLabel")}</Label>
          <textarea
            rows={2}
            value={note}
            onChange={(e) => setNote(e.target.value)}
            placeholder={t("customerApp.productEnquiry.callback.notePlaceholder")}
            className="w-full rounded-xl border border-border bg-surface px-3.5 py-2.5 text-sm text-text outline-none placeholder:text-text-muted"
          />
        </div>

        {requestCallbackMut.isError ? <p className="text-xs text-danger">{(requestCallbackMut.error as Error).message}</p> : null}

        <div className="flex justify-end">
          <Button
            type="button"
            disabled={!slotId || !orgId || requestCallbackMut.isPending}
            onClick={() =>
              requestCallbackMut.mutate({
                orgId: orgId!,
                scheduledDate,
                slotId: slotId!,
                productId,
                note: note.trim(),
              })
            }
          >
            {requestCallbackMut.isPending ? <Loader2 className="size-3.5 animate-spin" /> : t("customerApp.productEnquiry.callback.submit")}
          </Button>
        </div>
      </Card>
    </div>
  )
}
