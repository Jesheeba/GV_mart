import { useMemo, useState } from "react"
import { useTranslation } from "react-i18next"
import { useNavigate } from "react-router-dom"
import { AlertTriangle, ChevronLeft, ChevronRight, Loader2, Wand2 } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Card } from "@/components/ui/card"
import { DatePicker } from "@/components/ui/date-picker"
import { Skeleton } from "@/components/ui/skeleton"
import { cn } from "@/lib/utils"
import { useProfile } from "@/hooks/useProfile"
import { useAppointmentsRange, useAssignTicketTechnician, useAutoAssignTicket, useTechnicians, useUnassignAppointment } from "@/hooks/useService"
import type { AppointmentListItem } from "@/services/service"
import { PriorityBadge, TicketTypeBadge } from "./TicketBadges"

function toDateInput(d: Date) {
  return d.toISOString().slice(0, 10)
}

export function AppointmentsPage() {
  const { t } = useTranslation()
  const navigate = useNavigate()
  const { data: profile } = useProfile()
  const orgId = profile?.org_id

  const [day, setDay] = useState(() => new Date())
  const dayStr = toDateInput(day)
  const fromIso = `${dayStr}T00:00:00`
  const toIso = `${dayStr}T23:59:59`

  const { data: appointments, isLoading, isError, refetch } = useAppointmentsRange(orgId, fromIso, toIso)
  const { data: technicians } = useTechnicians(orgId)
  const autoAssign = useAutoAssignTicket()
  const assign = useAssignTicketTechnician()
  const unassign = useUnassignAppointment()

  const [draggingId, setDraggingId] = useState<string | null>(null)
  const [dragOverTechId, setDragOverTechId] = useState<string | null>(null)
  const [dragOverUnassign, setDragOverUnassign] = useState(false)
  const [conflict, setConflict] = useState<{ appointmentId: string; technicianId: string; reasonKey: string } | null>(null)
  const [selected, setSelected] = useState<AppointmentListItem | null>(null)
  const [pickerTechId, setPickerTechId] = useState("")

  const unassigned = useMemo(() => (appointments ?? []).filter((a) => !a.technician_id && a.status === "scheduled"), [appointments])
  const selectedLive = useMemo(() => (appointments ?? []).find((a) => a.id === selected?.id) ?? selected, [appointments, selected])

  function selectAppointment(a: AppointmentListItem) {
    setSelected(a)
    setPickerTechId("")
  }

  function byTechnician(techId: string) {
    // B3: a booking bumped here because its requested date was full is
    // first-priority for this (its new) date — surfaced by sorting it to
    // the front of the technician's card list, not just a badge.
    return (appointments ?? [])
      .filter((a) => a.technician_id === techId)
      .sort((a, b) => Number(b.next_day_priority) - Number(a.next_day_priority))
  }

  function handleDrop(techId: string) {
    setDragOverTechId(null)
    if (!draggingId) return
    const appt = (appointments ?? []).find((a) => a.id === draggingId)
    setDraggingId(null)
    if (!appt) return
    assign.mutate(
      { appointmentId: appt.id, technicianId: techId },
      {
        onSuccess: (result) => {
          if (!result.assigned && result.reason_key) {
            setConflict({ appointmentId: appt.id, technicianId: techId, reasonKey: result.reason_key })
          }
        },
      }
    )
  }

  function confirmAndUnassign(appt: AppointmentListItem) {
    if (!window.confirm(t("service.appointments.confirmUnassign", { name: appt.service_tickets?.customers?.name ?? "" }))) return
    unassign.mutate(appt.id)
  }

  function forceReassign() {
    if (!conflict) return
    assign.mutate({ appointmentId: conflict.appointmentId, technicianId: conflict.technicianId, force: true })
    setConflict(null)
  }

  return (
    <div className="space-y-4 pt-2">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <div>
          <h1 className="text-2xl font-bold text-text">{t("service.appointments.title")}</h1>
          <p className="text-sm text-text-muted">{t("service.appointments.subtitle")}</p>
        </div>
        <div className="flex items-center gap-2">
          <Button size="icon-sm" variant="outline" onClick={() => setDay((d) => new Date(d.getTime() - 86_400_000))}>
            <ChevronLeft className="size-4" />
          </Button>
          <DatePicker value={dayStr} onChange={(v) => setDay(new Date(`${v}T00:00:00`))} className="w-40" />
          <Button size="icon-sm" variant="outline" onClick={() => setDay((d) => new Date(d.getTime() + 86_400_000))}>
            <ChevronRight className="size-4" />
          </Button>
        </div>
      </div>

      {conflict ? (
        <Card size="sm" className="flex-row items-center gap-3 border-warning/40 bg-warning/5 px-4">
          <AlertTriangle className="size-4 shrink-0 text-warning" />
          <p className="flex-1 text-sm text-text">{t(conflict.reasonKey)}</p>
          <Button size="sm" variant="outline" onClick={() => setConflict(null)}>
            {t("common.cancel")}
          </Button>
          <Button size="sm" variant="accent" disabled={assign.isPending} onClick={forceReassign}>
            {assign.isPending ? <Loader2 className="size-3.5 animate-spin" /> : null}
            {t("service.appointments.forceReassign")}
          </Button>
        </Card>
      ) : null}

      {assign.isError || autoAssign.isError || unassign.isError ? (
        <Card size="sm" className="flex-row items-center gap-3 border-danger/40 bg-danger/5 px-4">
          <AlertTriangle className="size-4 shrink-0 text-danger" />
          <p className="flex-1 text-sm text-danger">
            {((assign.error ?? autoAssign.error ?? unassign.error) as Error).message}
          </p>
        </Card>
      ) : null}

      <div className="grid grid-cols-1 gap-4 lg:grid-cols-[1fr_320px]">
        {/* Left: per-technician day timeline */}
        <Card className="gap-3 px-5">
          <h2 className="text-sm font-semibold text-text">{t("service.appointments.timeline")}</h2>
          {isError ? (
            <p className="text-sm text-danger">
              {t("service.loadFailed")}{" "}
              <button className="underline" onClick={() => refetch()}>
                {t("common.retry")}
              </button>
            </p>
          ) : isLoading ? (
            <Skeleton className="h-64 w-full" />
          ) : (technicians ?? []).length === 0 ? (
            <p className="text-sm text-text-muted">{t("service.appointments.noTechnicians")}</p>
          ) : (
            <div className="space-y-3">
              {(technicians ?? []).map((tc) => (
                <div
                  key={tc.id}
                  onDragOver={(e) => e.preventDefault()}
                  onDragEnter={() => setDragOverTechId(tc.id)}
                  onDragLeave={(e) => {
                    if (!e.currentTarget.contains(e.relatedTarget as Node)) setDragOverTechId((id) => (id === tc.id ? null : id))
                  }}
                  onDrop={() => handleDrop(tc.id)}
                  className={cn(
                    "rounded-xl border border-border p-3",
                    dragOverTechId === tc.id && "border-accent bg-accent-soft"
                  )}
                >
                  <div className="mb-2 flex items-center gap-2">
                    <span className={`size-1.5 rounded-full ${tc.is_on_duty ? "bg-success" : "bg-text-muted"}`} />
                    <span className="text-sm font-medium text-text">{tc.full_name}</span>
                    {!tc.is_on_duty ? <span className="text-xs text-text-muted">({t("service.detail.offDuty")})</span> : null}
                    {assign.isPending && assign.variables?.technicianId === tc.id ? (
                      <Loader2 className="size-3.5 animate-spin text-text-muted" />
                    ) : null}
                  </div>
                  <div className="flex flex-wrap gap-2">
                    {byTechnician(tc.id).length === 0 ? (
                      <p className="text-xs text-text-muted">{t("service.appointments.noJobs")}</p>
                    ) : (
                      byTechnician(tc.id).map((a) => (
                        <div
                          key={a.id}
                          draggable
                          role="button"
                          tabIndex={0}
                          onDragStart={() => setDraggingId(a.id)}
                          onDragEnd={() => setDraggingId(null)}
                          onClick={() => selectAppointment(a)}
                          onKeyDown={(e) => {
                            if (e.key === "Enter" || e.key === " ") {
                              e.preventDefault()
                              selectAppointment(a)
                            }
                          }}
                          className={cn(
                            "w-48 cursor-grab rounded-lg border border-border bg-surface-alt p-2 text-xs active:cursor-grabbing",
                            draggingId === a.id && "opacity-50"
                          )}
                        >
                          <div className="flex items-center justify-between gap-1">
                            <div className="font-medium text-text">{a.service_tickets?.customers?.name ?? "—"}</div>
                            {a.next_day_priority ? (
                              <span className="shrink-0 rounded-full bg-warning/15 px-1.5 py-0.5 text-[10px] font-semibold text-warning" title={t("service.detail.nextDayPriorityBadge")}>
                                {t("service.appointments.nextDayPriorityShort")}
                              </span>
                            ) : null}
                          </div>
                          <div className="truncate text-text-muted">{a.service_tickets?.name_of_complaint}</div>
                          <div className="mt-1 flex items-center gap-1">
                            {a.service_tickets?.type ? <TicketTypeBadge type={a.service_tickets.type} /> : null}
                            {a.service_tickets?.priority ? <PriorityBadge priority={a.service_tickets.priority} /> : null}
                          </div>
                          <div className="mt-1 text-text-muted">
                            {a.mode === "always" ? t("service.appointment.always") : a.scheduled_at ? new Date(a.scheduled_at).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" }) : "—"}
                          </div>
                        </div>
                      ))
                    )}
                  </div>
                </div>
              ))}

              <div
                onDragOver={(e) => e.preventDefault()}
                onDragEnter={() => setDragOverUnassign(true)}
                onDragLeave={(e) => {
                  if (!e.currentTarget.contains(e.relatedTarget as Node)) setDragOverUnassign(false)
                }}
                onDrop={() => {
                  setDragOverUnassign(false)
                  if (!draggingId) return
                  const appt = (appointments ?? []).find((a) => a.id === draggingId)
                  setDraggingId(null)
                  if (!appt || !appt.technician_id) return
                  confirmAndUnassign(appt)
                }}
                className={cn(
                  "rounded-xl border border-dashed border-border p-3 text-center text-xs text-text-muted",
                  dragOverUnassign && "border-accent bg-accent-soft text-accent"
                )}
              >
                {t("service.appointments.dropToUnassignHint")}
              </div>
            </div>
          )}
        </Card>

        {/* Right: auto-assign engine + unassigned queue */}
        <div className="space-y-4">
          <Card className="gap-2 px-5">
            <h2 className="flex items-center gap-1.5 text-sm font-semibold text-text">
              <Wand2 className="size-4" /> {t("service.appointments.autoAssignEngine")}
            </h2>
            <p className="text-xs text-text-muted">{t("service.appointments.autoAssignDescription")}</p>
          </Card>

          <Card className="gap-3 px-5">
            <h2 className="text-sm font-semibold text-text">{t("service.appointments.unassigned", { count: unassigned.length })}</h2>
            {isLoading ? (
              <Skeleton className="h-32 w-full" />
            ) : unassigned.length === 0 ? (
              <p className="text-sm text-text-muted">{t("service.appointments.noUnassigned")}</p>
            ) : (
              <div className="space-y-2">
                {unassigned.map((a) => (
                  <div
                    key={a.id}
                    draggable
                    onDragStart={() => setDraggingId(a.id)}
                    onDragEnd={() => setDraggingId(null)}
                    className={cn(
                      "cursor-grab rounded-lg border border-border p-2.5 text-xs active:cursor-grabbing",
                      draggingId === a.id && "opacity-50"
                    )}
                  >
                    <button type="button" className="w-full text-left" onClick={() => selectAppointment(a)}>
                      <div className="font-medium text-text">{a.service_tickets?.customers?.name ?? "—"}</div>
                      <div className="truncate text-text-muted">{a.service_tickets?.name_of_complaint}</div>
                    </button>
                    <div className="mt-1 flex items-center justify-between">
                      {a.service_tickets?.priority ? <PriorityBadge priority={a.service_tickets.priority} /> : <span />}
                      <Button
                        size="xs"
                        variant="outline"
                        disabled={autoAssign.isPending}
                        onClick={() => a.service_tickets && autoAssign.mutate(a.service_tickets.id)}
                      >
                        {t("service.detail.autoAssign")}
                      </Button>
                    </div>
                  </div>
                ))}
              </div>
            )}
          </Card>

          {selected && selectedLive ? (
            <Card size="sm" className="gap-2 px-4">
              <h3 className="text-xs font-semibold text-text-muted">{t("service.appointments.selected")}</h3>
              <p className="text-sm text-text">{selectedLive.service_tickets?.name_of_complaint}</p>
              <p className="text-xs text-text-muted">
                {selectedLive.technician_id
                  ? t("service.detail.assignedTo", { name: selectedLive.technicians?.profiles?.full_name ?? "—" })
                  : t("service.appointments.noTechnicianAssigned")}
              </p>
              <div className="flex flex-wrap items-center gap-2">
                <select
                  value={pickerTechId}
                  onChange={(e) => setPickerTechId(e.target.value)}
                  className="h-8 rounded-xl border border-border bg-surface px-3 text-sm text-text outline-none"
                >
                  <option value="">{t("service.detail.pickTechnician")}</option>
                  {(technicians ?? []).map((tc) => (
                    <option key={tc.id} value={tc.id}>
                      {tc.full_name} {tc.is_on_duty ? "" : `(${t("service.detail.offDuty")})`}
                    </option>
                  ))}
                </select>
                <Button
                  size="sm"
                  variant="outline"
                  disabled={!pickerTechId || assign.isPending}
                  onClick={() =>
                    assign.mutate(
                      { appointmentId: selectedLive.id, technicianId: pickerTechId },
                      {
                        onSuccess: (result) => {
                          if (!result.assigned && result.reason_key) {
                            setConflict({ appointmentId: selectedLive.id, technicianId: pickerTechId, reasonKey: result.reason_key })
                          }
                        },
                      }
                    )
                  }
                >
                  {assign.isPending && assign.variables?.appointmentId === selectedLive.id ? <Loader2 className="size-3.5 animate-spin" /> : null}
                  {selectedLive.technician_id ? t("service.appointments.reassign") : t("service.detail.assignManually")}
                </Button>
                {selectedLive.technician_id ? (
                  <Button
                    size="sm"
                    variant="outline"
                    disabled={unassign.isPending}
                    onClick={() => confirmAndUnassign(selectedLive)}
                  >
                    {unassign.isPending && unassign.variables === selectedLive.id ? <Loader2 className="size-3.5 animate-spin" /> : null}
                    {t("service.appointments.unassign")}
                  </Button>
                ) : null}
              </div>
              <Button size="sm" variant="outline" onClick={() => selectedLive.service_tickets && navigate(`/admin/service/${selectedLive.service_tickets.id}`)}>
                {t("service.appointments.viewTicket")}
              </Button>
            </Card>
          ) : null}
        </div>
      </div>
    </div>
  )
}
