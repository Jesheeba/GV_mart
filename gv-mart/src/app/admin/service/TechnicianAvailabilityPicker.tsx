// Urgent item #5 — availability-assisted scheduling for the master's
// create/assign-complaint flow. Lets the master go either way:
//   (a) technician-first: pick a technician, see their free/busy slots on
//       `date`, click a free slot.
//   (b) date-first: see every technician's free/busy slots on `date` at
//       once, click a technician's free slot to pick both together.
// Busy slots are always shown (never hidden), and this component never
// books or assigns anything itself — it only reports a pick via
// onSelectTechnician/onSlotSelect. The caller decides what that pick means:
// NewComplaintPage uses a slot to fill the appointment time field;
// TicketDetailPage's Assignment card only uses the technician pick (its
// appointment time is already fixed) and still goes through the existing
// assign_ticket_technician RPC, which is what actually refuses/warns on a
// real conflict (service.assign.technicianBusy) — this picker's own
// "busy" chips are a preview from the same read-only RPC, not a second
// source of truth, and never silently let a double-booking through on
// their own.
import { useState } from "react"
import { useTranslation } from "react-i18next"
import { CalendarOff, Clock, Loader2 } from "lucide-react"
import { SegButton } from "@/components/shared/SegButton"
import { useTechnicianAvailability, useTechniciansAvailability } from "@/hooks/useService"
import { isNotYetAvailableError } from "@/lib/supabaseErrors"
import type { TechnicianAvailabilityRow } from "@/lib/technician-availability"
import type { TimeWindow } from "@/lib/booking-window"

export type TechnicianOption = { id: string; full_name: string }
export type AvailabilitySlotPick = { technicianId: string; technicianName: string; slot: TimeWindow }

type Props = {
  orgId: string | undefined
  /** yyyy-mm-dd. Date selection itself is owned by the caller (the page's
   * own date picker / the appointment's already-fixed date) — this
   * component only reads availability for it. */
  date: string | null
  technicians: TechnicianOption[]
  estimatedMinutes?: number
  selectedTechnicianId: string | null
  onSelectTechnician: (id: string) => void
  /** Omit on a screen where the appointment's time is already fixed (e.g.
   * TicketDetailPage) — the picker then only helps choose WHICH
   * technician, slots are shown but not clickable. */
  onSlotSelect?: (pick: AvailabilitySlotPick) => void
}

export function TechnicianAvailabilityPicker({
  orgId,
  date,
  technicians,
  estimatedMinutes,
  selectedTechnicianId,
  onSelectTechnician,
  onSlotSelect,
}: Props) {
  const { t } = useTranslation()
  const [mode, setMode] = useState<"date" | "technician">("date")

  const allAvail = useTechniciansAvailability(orgId, date ?? undefined)
  const oneAvail = useTechnicianAvailability(orgId, date ?? undefined, mode === "technician" ? selectedTechnicianId ?? undefined : undefined)

  if (!date) {
    return <p className="text-xs text-text-muted">{t("service.availability.pickDateFirst")}</p>
  }

  if (isNotYetAvailableError(allAvail.error) || isNotYetAvailableError(oneAvail.error)) {
    return <p className="text-xs text-text-muted">{t("service.availability.notAvailableYet")}</p>
  }

  function renderSlots(row: TechnicianAvailabilityRow) {
    if (row.isOnLeave) {
      return (
        <p className="flex items-center gap-1.5 text-xs text-danger">
          <CalendarOff className="size-3.5" /> {t("service.availability.onLeave")}
        </p>
      )
    }
    return (
      <div className="flex flex-wrap gap-1.5">
        {row.busyWindows.map((w, i) => (
          <span key={`busy-${i}`} className="rounded-full border border-danger/30 bg-danger/10 px-2.5 py-1 text-xs font-medium text-danger">
            {w.start}–{w.end}
          </span>
        ))}
        {row.freeWindows.length === 0 ? (
          <span className="text-xs text-text-muted">{t("service.availability.noFreeWindow")}</span>
        ) : (
          row.freeWindows.map((g, i) => {
            const narrow = estimatedMinutes != null && g.minutes < estimatedMinutes
            return (
              <button
                key={`free-${i}`}
                type="button"
                disabled={!onSlotSelect}
                onClick={() => {
                  onSelectTechnician(row.technicianId)
                  onSlotSelect?.({ technicianId: row.technicianId, technicianName: row.technicianName, slot: { start: g.start, end: g.end } })
                }}
                title={narrow ? t("service.availability.narrowSlotHint", { minutes: estimatedMinutes }) : undefined}
                className={`rounded-full border px-2.5 py-1 text-xs font-medium transition-colors ${
                  narrow ? "border-warning/40 bg-warning/10 text-warning" : "border-success/30 bg-success/10 text-success"
                } ${onSlotSelect ? "cursor-pointer hover:opacity-80" : "cursor-default"}`}
              >
                {g.start}–{g.end}
              </button>
            )
          })
        )}
      </div>
    )
  }

  return (
    <div className="space-y-2.5 rounded-xl border border-border p-3">
      <div className="flex items-center justify-between gap-2">
        <p className="flex items-center gap-1.5 text-xs font-medium text-text-muted">
          <Clock className="size-3.5" /> {t("service.availability.title")}
        </p>
        <div className="flex gap-1 rounded-full bg-surface-alt p-0.5">
          {(["date", "technician"] as const).map((m) => (
            <SegButton key={m} active={mode === m} onClick={() => setMode(m)} className="px-2.5 py-1 text-xs">
              {t(`service.availability.mode.${m}`)}
            </SegButton>
          ))}
        </div>
      </div>

      {mode === "date" ? (
        allAvail.isLoading ? (
          <p className="flex items-center gap-2 text-xs text-text-muted">
            <Loader2 className="size-3.5 animate-spin" /> {t("common.loading")}
          </p>
        ) : (allAvail.data ?? []).length === 0 ? (
          <p className="text-xs text-text-muted">{t("service.availability.noTechnicians")}</p>
        ) : (
          <div className="space-y-2">
            {(allAvail.data ?? []).map((row) => (
              <div
                key={row.technicianId}
                className={`space-y-1 rounded-lg border px-2.5 py-2 ${
                  selectedTechnicianId === row.technicianId ? "border-accent bg-accent-soft" : "border-border"
                }`}
              >
                <button type="button" onClick={() => onSelectTechnician(row.technicianId)} className="text-sm font-medium text-text">
                  {row.technicianName}
                </button>
                {renderSlots(row)}
              </div>
            ))}
          </div>
        )
      ) : (
        <div className="space-y-2">
          <select
            value={selectedTechnicianId ?? ""}
            onChange={(e) => onSelectTechnician(e.target.value)}
            className="h-9 w-full rounded-xl border border-border bg-surface px-3 text-sm text-text outline-none sm:max-w-xs"
          >
            <option value="">{t("service.detail.pickTechnician")}</option>
            {technicians.map((tc) => (
              <option key={tc.id} value={tc.id}>
                {tc.full_name}
              </option>
            ))}
          </select>
          {selectedTechnicianId ? (
            oneAvail.isLoading ? (
              <p className="flex items-center gap-2 text-xs text-text-muted">
                <Loader2 className="size-3.5 animate-spin" /> {t("common.loading")}
              </p>
            ) : oneAvail.data ? (
              renderSlots(oneAvail.data)
            ) : null
          ) : null}
        </div>
      )}
    </div>
  )
}
