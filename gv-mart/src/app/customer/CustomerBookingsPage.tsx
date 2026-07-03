import { useTranslation } from "react-i18next"
import { useNavigate } from "react-router-dom"
import { CalendarClock, ChevronRight, Wrench } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Card } from "@/components/ui/card"
import { StatusDot, type StatusTone } from "@/components/shared/StatusDot"
import { FullPageError, FullPageLoader } from "@/components/shared/FullPageLoader"
import { useMyCustomerId, useMyTickets } from "@/hooks/useCustomerApp"

const STATUS_TONE: Record<string, StatusTone> = {
  open: "warning",
  assigned: "info",
  in_progress: "warning",
  completed: "success",
  cancelled: "neutral",
}

export function CustomerBookingsPage() {
  const { t } = useTranslation()
  const navigate = useNavigate()
  const { customerId, isLoading: loadingId } = useMyCustomerId()
  const { data: tickets, isLoading, isError, refetch } = useMyTickets(customerId)

  if (loadingId || isLoading) return <FullPageLoader label={t("common.loading")} />
  if (isError) {
    return <FullPageError message={t("customerApp.bookings.loadError")} onRetry={() => refetch()} retryLabel={t("common.retry")} />
  }

  const list = tickets ?? []
  const upcoming = list.filter((tk) => tk.status === "open" || tk.status === "assigned" || tk.status === "in_progress")
  const past = list.filter((tk) => tk.status === "completed" || tk.status === "cancelled")

  return (
    <div className="space-y-4 pb-4 pt-2">
      <div className="flex items-center justify-between">
        <h1 className="text-xl font-bold text-text">{t("customerApp.bookings.title")}</h1>
        <Button size="sm" onClick={() => navigate("/customer/book-service")}>
          <Wrench className="size-3.5" />
          {t("customerApp.bookings.newBooking")}
        </Button>
      </div>

      {list.length === 0 ? (
        <Card className="items-center gap-1.5 py-8 text-center">
          <CalendarClock className="size-6 text-text-muted" />
          <p className="text-sm text-text-muted">{t("customerApp.bookings.empty")}</p>
          <Button size="sm" variant="outline" onClick={() => navigate("/customer/book-service")}>
            {t("customerApp.bookings.newBooking")}
          </Button>
        </Card>
      ) : (
        <>
          {upcoming.length > 0 ? (
            <div className="space-y-2">
              <h2 className="px-1 text-sm font-semibold text-text">{t("customerApp.bookings.upcoming")}</h2>
              {upcoming.map((tk) => (
                <BookingRow key={tk.id} ticket={tk} onClick={() => navigate(`/customer/bookings/${tk.id}`)} />
              ))}
            </div>
          ) : null}

          {past.length > 0 ? (
            <div className="space-y-2">
              <h2 className="px-1 text-sm font-semibold text-text">{t("customerApp.bookings.past")}</h2>
              {past.map((tk) => (
                <BookingRow key={tk.id} ticket={tk} onClick={() => navigate(`/customer/bookings/${tk.id}`)} />
              ))}
            </div>
          ) : null}
        </>
      )}
    </div>
  )
}

type TicketRow = NonNullable<ReturnType<typeof useMyTickets>["data"]>[number]

function BookingRow({ ticket, onClick }: { ticket: TicketRow; onClick: () => void }) {
  const { t } = useTranslation()
  const appt = ticket.appointments?.[0]
  const dateLabel = appt?.scheduled_at
    ? new Date(appt.scheduled_at).toLocaleString(undefined, { dateStyle: "medium", timeStyle: "short" })
    : t("customerApp.bookings.anytime")

  return (
    <Card size="sm" className="cursor-pointer gap-1.5" onClick={onClick}>
      <div className="flex items-center justify-between px-1">
        <p className="text-sm font-semibold text-text">{ticket.products?.name ?? ticket.name_of_complaint ?? t("customerApp.bookings.generalService")}</p>
        <ChevronRight className="size-4 shrink-0 text-text-muted" />
      </div>
      <div className="flex items-center justify-between px-1">
        <StatusDot tone={STATUS_TONE[ticket.status] ?? "neutral"} label={t(`customerApp.bookings.status.${ticket.status}`)} />
        <span className="text-xs text-text-muted">{dateLabel}</span>
      </div>
      {ticket.name_of_complaint ? <p className="truncate px-1 text-xs text-text-muted">{ticket.name_of_complaint}</p> : null}
    </Card>
  )
}
