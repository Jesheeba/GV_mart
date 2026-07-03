import { useMemo, useState } from "react"
import { useTranslation } from "react-i18next"
import { useNavigate } from "react-router-dom"
import { AlertTriangle, ChevronLeft, ChevronRight, Wand2 } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Card } from "@/components/ui/card"
import { Skeleton } from "@/components/ui/skeleton"
import { useProfile } from "@/hooks/useProfile"
import { useAppointmentsRange, useAssignTicketTechnician, useAutoAssignTicket, useTechnicians } from "@/hooks/useService"
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

  const [draggingId, setDraggingId] = useState<string | null>(null)
  const [conflict, setConflict] = useState<{ appointmentId: string; technicianId: string; reasonKey: string } | null>(null)
  const [selected, setSelected] = useState<AppointmentListItem | null>(null)

  const unassigned = useMemo(() => (appointments ?? []).filter((a) => !a.technician_id && a.status === "scheduled"), [appointments])

  function byTechnician(techId: string) {
    return (appointments ?? []).filter((a) => a.technician_id === techId)
  }

  function handleDrop(techId: string) {
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
          <input
            type="date"
            value={dayStr}
            onChange={(e) => setDay(new Date(`${e.target.value}T00:00:00`))}
            className="h-10 rounded-xl border border-border bg-surface px-3 text-sm text-text outline-none"
          />
          <Button size="icon-sm" variant="outline" onClick={() => setDay((d) => new Date(d.getTime() + 86_400_000))}>
            <ChevronRight className="size-4" />
          </Button>
        </div>
      </div>

      {conflict ? (
        <Card size="sm" className="flex-row items-center gap-3 border-warning/40 bg-warning/5">
          <AlertTriangle className="size-4 shrink-0 text-warning" />
          <p className="flex-1 text-sm text-text">{t(conflict.reasonKey)}</p>
          <Button size="sm" variant="outline" onClick={() => setConflict(null)}>
            {t("common.cancel")}
          </Button>
          <Button size="sm" variant="accent" onClick={forceReassign}>
            {t("service.appointments.forceReassign")}
          </Button>
        </Card>
      ) : null}

      <div className="grid grid-cols-1 gap-4 lg:grid-cols-[1fr_320px]">
        {/* Left: per-technician day timeline */}
        <Card className="gap-3">
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
                  onDrop={() => handleDrop(tc.id)}
                  className="rounded-xl border border-border p-3"
                >
                  <div className="mb-2 flex items-center gap-2">
                    <span className={`size-1.5 rounded-full ${tc.is_on_duty ? "bg-success" : "bg-text-muted"}`} />
                    <span className="text-sm font-medium text-text">{tc.full_name}</span>
                    {!tc.is_on_duty ? <span className="text-xs text-text-muted">({t("service.detail.offDuty")})</span> : null}
                  </div>
                  <div className="flex flex-wrap gap-2">
                    {byTechnician(tc.id).length === 0 ? (
                      <p className="text-xs text-text-muted">{t("service.appointments.noJobs")}</p>
                    ) : (
                      byTechnician(tc.id).map((a) => (
                        <div
                          key={a.id}
                          draggable
                          onDragStart={() => setDraggingId(a.id)}
                          onClick={() => setSelected(a)}
                          className="w-48 cursor-grab rounded-lg border border-border bg-surface-alt p-2 text-xs active:cursor-grabbing"
                        >
                          <div className="font-medium text-text">{a.service_tickets?.customers?.name ?? "—"}</div>
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
                onDrop={() => {
                  if (!draggingId) return
                  const appt = (appointments ?? []).find((a) => a.id === draggingId)
                  setDraggingId(null)
                  if (appt) navigate(`/admin/service/${appt.service_tickets?.id}`)
                }}
                className="rounded-xl border border-dashed border-border p-3 text-center text-xs text-text-muted"
              >
                {t("service.appointments.dropToUnassignHint")}
              </div>
            </div>
          )}
        </Card>

        {/* Right: auto-assign engine + unassigned queue */}
        <div className="space-y-4">
          <Card className="gap-2">
            <h2 className="flex items-center gap-1.5 text-sm font-semibold text-text">
              <Wand2 className="size-4" /> {t("service.appointments.autoAssignEngine")}
            </h2>
            <p className="text-xs text-text-muted">{t("service.appointments.autoAssignDescription")}</p>
          </Card>

          <Card className="gap-3">
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
                    className="cursor-grab rounded-lg border border-border p-2.5 text-xs active:cursor-grabbing"
                  >
                    <div className="font-medium text-text">{a.service_tickets?.customers?.name ?? "—"}</div>
                    <div className="truncate text-text-muted">{a.service_tickets?.name_of_complaint}</div>
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

          {selected ? (
            <Card size="sm" className="gap-2">
              <h3 className="text-xs font-semibold text-text-muted">{t("service.appointments.selected")}</h3>
              <p className="text-sm text-text">{selected.service_tickets?.name_of_complaint}</p>
              <Button size="sm" variant="outline" onClick={() => selected.service_tickets && navigate(`/admin/service/${selected.service_tickets.id}`)}>
                {t("service.appointments.viewTicket")}
              </Button>
            </Card>
          ) : null}
        </div>
      </div>
    </div>
  )
}
