import { type ReactNode, useEffect, useRef, useState } from "react"
import { useTranslation } from "react-i18next"
import { useNavigate } from "react-router-dom"
import { CalendarClock, ChevronLeft, ChevronRight, SlidersHorizontal, Wrench, X } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Card } from "@/components/ui/card"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { DatePicker } from "@/components/ui/date-picker"
import { Skeleton } from "@/components/ui/skeleton"
import { StatusDot, type StatusTone } from "@/components/shared/StatusDot"
import { FullPageError } from "@/components/shared/FullPageLoader"
import { useMyCustomerId, useMyTicketsFiltered, useMyTicketTechnicians, useResolveStaleBookings } from "@/hooks/useCustomerApp"
import { TICKET_FILTER_PAGE_SIZE, type FilteredTicketItem, type TicketFilters } from "@/services/customerApp"

const STATUS_TONE: Record<string, StatusTone> = {
  open: "warning",
  assigned: "info",
  in_progress: "warning",
  completed: "success",
  cancelled: "neutral",
}

// Real product categories this app actually sells (brand_category enum) —
// the spec's own list (RO/AC/Inverter/Washing Machine/Refrigerator/Others)
// doesn't match the schema, so those two extra options would just always
// return zero rows. See 20260730120000_customer_ticket_filters.sql's header.
const PRODUCT_CATEGORIES = ["ro", "ac", "inverter", "battery"] as const
const BOOKING_STATUSES = ["open", "assigned", "in_progress", "completed", "cancelled"] as const
const AMC_STATUSES = ["active", "due_soon", "expired"] as const
const SERVICE_TYPES = ["paid", "warranty", "amc", "installation"] as const

const EMPTY_FILTERS: TicketFilters = {}

export function CustomerBookingsPage() {
  const { t } = useTranslation()
  const navigate = useNavigate()
  const { customerId, orgId, isLoading: loadingId } = useMyCustomerId()
  const [filters, setFilters] = useState<TicketFilters>(EMPTY_FILTERS)
  const [page, setPage] = useState(0)
  const [filtersOpen, setFiltersOpen] = useState(false)
  const { data, isLoading, isError, refetch } = useMyTicketsFiltered(customerId, filters, page)
  const { data: technicians } = useMyTicketTechnicians(customerId)

  // Task 4 — resolve-on-view: best-effort, once per mount, so any of this
  // customer's bookings whose day ended with no technician assigned gets
  // flagged (and admins notified) just by the customer opening this page.
  const resolveStale = useResolveStaleBookings(orgId)
  const resolvedOnceRef = useRef(false)
  useEffect(() => {
    if (resolvedOnceRef.current || !orgId) return
    resolvedOnceRef.current = true
    resolveStale.mutate()
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [orgId])

  function updateFilter<K extends keyof TicketFilters>(key: K, value: TicketFilters[K] | "") {
    setFilters((prev) => ({ ...prev, [key]: value || undefined }))
    setPage(0)
  }

  const activeFilterCount = Object.values(filters).filter(Boolean).length
  const items = data?.items ?? []
  const total = data?.total_count ?? 0
  const from = total === 0 ? 0 : page * TICKET_FILTER_PAGE_SIZE + 1
  const to = Math.min(total, (page + 1) * TICKET_FILTER_PAGE_SIZE)

  if (isError) {
    return <FullPageError message={t("customerApp.bookings.loadError")} onRetry={() => refetch()} retryLabel={t("common.retry")} />
  }

  return (
    <div className="space-y-4 pb-4 pt-2">
      <div className="flex items-center justify-between">
        <h1 className="text-xl font-bold text-text">{t("customerApp.bookings.title")}</h1>
        <Button size="sm" onClick={() => navigate("/customer/book-service")}>
          <Wrench className="size-3.5" />
          {t("customerApp.bookings.newBooking")}
        </Button>
      </div>

      <div className="flex items-center gap-2">
        <Button size="sm" variant="outline" onClick={() => setFiltersOpen((v) => !v)}>
          <SlidersHorizontal className="size-3.5" />
          {t("customerApp.bookings.filters.toggle")}
          {activeFilterCount > 0 ? (
            <span className="ml-1 flex size-4 items-center justify-center rounded-full bg-accent text-[10px] font-semibold text-white">
              {activeFilterCount}
            </span>
          ) : null}
        </Button>
        {activeFilterCount > 0 ? (
          <Button
            size="sm"
            variant="ghost"
            onClick={() => {
              setFilters(EMPTY_FILTERS)
              setPage(0)
            }}
          >
            <X className="size-3.5" />
            {t("customerApp.bookings.filters.clear")}
          </Button>
        ) : null}
      </div>

      {filtersOpen ? (
        <Card className="gap-2.5">
          <div className="grid grid-cols-2 gap-2.5">
            <FilterField label={t("customerApp.bookings.filters.fromDate")}>
              <DatePicker value={filters.fromDate ?? ""} max={filters.toDate} onChange={(v) => updateFilter("fromDate", v)} className="h-9" />
            </FilterField>
            <FilterField label={t("customerApp.bookings.filters.toDate")}>
              <DatePicker value={filters.toDate ?? ""} min={filters.fromDate} onChange={(v) => updateFilter("toDate", v)} className="h-9" />
            </FilterField>
          </div>

          <FilterSelect
            label={t("customerApp.bookings.filters.productType")}
            value={filters.productCategory ?? ""}
            onChange={(v) => updateFilter("productCategory", v)}
            options={PRODUCT_CATEGORIES.map((c) => ({ value: c, label: t(`customerApp.bookService.category.${c}`) }))}
            allLabel={t("customerApp.bookings.filters.all")}
          />
          <FilterSelect
            label={t("customerApp.bookings.filters.bookingStatus")}
            value={filters.status ?? ""}
            onChange={(v) => updateFilter("status", v as TicketFilters["status"])}
            options={BOOKING_STATUSES.map((s) => ({ value: s, label: t(`customerApp.bookings.status.${s}`) }))}
            allLabel={t("customerApp.bookings.filters.all")}
          />
          <FilterSelect
            label={t("customerApp.bookings.filters.serviceType")}
            value={filters.serviceType ?? ""}
            onChange={(v) => updateFilter("serviceType", v as TicketFilters["serviceType"])}
            options={SERVICE_TYPES.map((s) => ({ value: s, label: t(`customerApp.bookings.filters.type.${s}`) }))}
            allLabel={t("customerApp.bookings.filters.all")}
          />
          <FilterSelect
            label={t("customerApp.bookings.filters.amcStatus")}
            value={filters.amcStatus ?? ""}
            onChange={(v) => updateFilter("amcStatus", v as TicketFilters["amcStatus"])}
            options={AMC_STATUSES.map((s) => ({ value: s, label: t(`customerApp.amc.status.${s}`) }))}
            allLabel={t("customerApp.bookings.filters.all")}
          />
          <FilterSelect
            label={t("customerApp.bookings.filters.assignedTechnician")}
            value={filters.technicianId ?? ""}
            onChange={(v) => updateFilter("technicianId", v)}
            options={(technicians ?? []).map((tc) => ({ value: tc.technician_id, label: tc.full_name }))}
            allLabel={t("customerApp.bookings.filters.all")}
          />

          <FilterField label={t("customerApp.bookings.filters.bookingNumber")}>
            <Input
              value={filters.bookingNumber ?? ""}
              onChange={(e) => updateFilter("bookingNumber", e.target.value)}
              placeholder={t("customerApp.bookings.filters.bookingNumberPlaceholder")}
            />
          </FilterField>
          <FilterField label={t("customerApp.bookings.filters.search")}>
            <Input
              value={filters.search ?? ""}
              onChange={(e) => updateFilter("search", e.target.value)}
              placeholder={t("customerApp.bookings.filters.searchPlaceholder")}
            />
          </FilterField>
        </Card>
      ) : null}

      {loadingId || isLoading ? (
        <div className="space-y-2">
          {Array.from({ length: 3 }).map((_, i) => (
            <Skeleton key={i} className="h-20 w-full rounded-xl" />
          ))}
        </div>
      ) : items.length === 0 ? (
        <Card className="items-center gap-1.5 py-8 text-center">
          <CalendarClock className="size-6 text-text-muted" />
          <p className="text-sm text-text-muted">{activeFilterCount > 0 ? t("customerApp.bookings.noResults") : t("customerApp.bookings.empty")}</p>
          {activeFilterCount === 0 ? (
            <Button size="sm" variant="outline" onClick={() => navigate("/customer/book-service")}>
              {t("customerApp.bookings.newBooking")}
            </Button>
          ) : null}
        </Card>
      ) : (
        <div className="space-y-2">
          {items.map((tk) => (
            <BookingRow key={tk.id} ticket={tk} onClick={() => navigate(`/customer/bookings/${tk.id}`)} />
          ))}
        </div>
      )}

      {total > TICKET_FILTER_PAGE_SIZE ? (
        <div className="flex items-center justify-between px-1">
          <Button size="sm" variant="outline" disabled={page === 0} onClick={() => setPage((p) => Math.max(0, p - 1))}>
            <ChevronLeft className="size-3.5" />
            {t("customerApp.bookings.pagination.previous")}
          </Button>
          <span className="text-xs text-text-muted">{t("customerApp.bookings.pagination.showing", { from, to, total })}</span>
          <Button size="sm" variant="outline" disabled={to >= total} onClick={() => setPage((p) => p + 1)}>
            {t("customerApp.bookings.pagination.next")}
            <ChevronRight className="size-3.5" />
          </Button>
        </div>
      ) : null}
    </div>
  )
}

function FilterField({ label, children }: { label: string; children: ReactNode }) {
  return (
    <div className="space-y-1">
      <Label className="text-xs text-text-muted">{label}</Label>
      {children}
    </div>
  )
}

function FilterSelect({
  label,
  value,
  onChange,
  options,
  allLabel,
}: {
  label: string
  value: string
  onChange: (v: string) => void
  options: { value: string; label: string }[]
  allLabel: string
}) {
  return (
    <div className="space-y-1">
      <Label className="text-xs text-text-muted">{label}</Label>
      <select
        value={value}
        onChange={(e) => onChange(e.target.value)}
        className="h-9 w-full rounded-xl border border-border bg-surface px-3 text-sm text-text outline-none"
      >
        <option value="">{allLabel}</option>
        {options.map((o) => (
          <option key={o.value} value={o.value}>
            {o.label}
          </option>
        ))}
      </select>
    </div>
  )
}

function BookingRow({ ticket, onClick }: { ticket: FilteredTicketItem; onClick: () => void }) {
  const { t } = useTranslation()
  const appt = ticket.appointment
  const dateLabel = appt?.scheduled_at
    ? new Date(appt.scheduled_at).toLocaleDateString(undefined, { dateStyle: "medium" })
    : t("customerApp.bookings.anytime")
  const slotLabel =
    appt?.slot_name && appt.slot_start_time && appt.slot_end_time
      ? `${appt.slot_name} (${appt.slot_start_time.slice(0, 5)}–${appt.slot_end_time.slice(0, 5)})`
      : null
  const needsFollowUp = !!appt?.follow_up_flagged_at

  return (
    <Card size="sm" className="cursor-pointer gap-1.5" onClick={onClick}>
      <div className="flex items-center justify-between px-1">
        <div className="flex min-w-0 items-center gap-1.5">
          <span className="shrink-0 text-xs font-bold text-text-muted">#{ticket.id.slice(0, 8)}</span>
          <p className="truncate text-sm font-semibold text-text">
            {ticket.product?.name ?? ticket.name_of_complaint ?? t("customerApp.bookings.generalService")}
          </p>
        </div>
        <ChevronRight className="size-4 shrink-0 text-text-muted" />
      </div>
      <div className="flex items-center justify-between px-1">
        <StatusDot tone={STATUS_TONE[ticket.status] ?? "neutral"} label={t(`customerApp.bookings.status.${ticket.status}`)} />
        <span className="text-xs text-text-muted">
          {dateLabel}
          {slotLabel ? ` · ${slotLabel}` : ""}
        </span>
      </div>
      {ticket.name_of_complaint ? <p className="truncate px-1 text-xs text-text-muted">{ticket.name_of_complaint}</p> : null}
      {needsFollowUp ? (
        <p className="rounded-lg bg-warning/10 px-2.5 py-1.5 text-xs font-medium text-warning">{t("customerApp.bookings.followUpNotice")}</p>
      ) : (
        <p className="px-1 text-xs text-text-muted">{appt?.technician?.full_name ?? t("customerApp.bookings.unassigned")}</p>
      )}
    </Card>
  )
}
