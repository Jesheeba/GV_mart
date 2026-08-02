import { useTranslation } from "react-i18next"
import { useNavigate } from "react-router-dom"
import { MapPin, Plus, TriangleAlert } from "lucide-react"
import { useTicketsList, useAppointmentsRange, useTechnicians } from "@/hooks/useService"
import { useAttendanceForDate } from "@/hooks/useTechniciansAdmin"
import { useOverdueSlaTickets } from "@/hooks/useSystemPages"
import { cn } from "@/lib/utils"
import { Button } from "@/components/ui/button"
import { KpiCard } from "@/components/shared/KpiCard"
import { HighlightKpiCard } from "@/components/shared/HighlightKpiCard"
import { todayRange } from "./dashboardMath"

const APPT_STATUS_TONE: Record<string, string> = {
  scheduled: "var(--text-muted)",
  in_progress: "#E8932B",
  completed: "#2FAE5F",
  cancelled: "#E5484D",
}

export function OpsDashboard({ orgId, firstName }: { orgId: string; firstName: string }) {
  const { t } = useTranslation()
  const navigate = useNavigate()
  const today = todayRange().from

  const { data: tickets, isLoading: ticketsLoading } = useTicketsList(orgId, {})
  const { data: technicians } = useTechnicians(orgId)
  const { data: appointments, isLoading: apptLoading } = useAppointmentsRange(orgId, `${today}T00:00:00`, `${today}T23:59:59`)
  const { data: attendance, isLoading: attendanceLoading } = useAttendanceForDate(orgId, today)
  const { data: overdueSla, isLoading: overdueSlaLoading } = useOverdueSlaTickets(orgId)

  const openTickets = tickets?.filter((tk) => tk.status !== "completed" && tk.status !== "cancelled") ?? []
  const urgentOpen = openTickets.filter((tk) => tk.priority === "very_urgent" || tk.priority === "urgent")
  const completedToday = tickets?.filter((tk) => tk.status === "completed" && tk.updated_at?.slice(0, 10) === today).length ?? 0

  const onDuty = attendance?.filter((a) => a.check_in_at).length ?? 0
  const totalTechs = technicians?.length ?? 0
  const onTime = attendance?.filter((a) => a.check_in_at && !a.is_late).length ?? 0
  const late = attendance?.filter((a) => a.is_late).length ?? 0
  const absent = Math.max(0, totalTechs - onDuty)
  const attendanceTotal = onTime + late + absent || 1
  const onTimePct = Math.round((onTime / attendanceTotal) * 100)
  const latePct = Math.round((late / attendanceTotal) * 100)

  return (
    <div>
      <div className="mb-5 flex flex-wrap items-end justify-between gap-4">
        <div>
          <h1 className="mb-1.5 text-[30px] font-extrabold leading-[1.05] tracking-tight text-text">{t("dashboard.welcomeBack", { name: firstName })}</h1>
          <p className="text-sm font-medium text-text-muted">{t("dashboard.operationAdminSubtitle")}</p>
        </div>
        <div className="flex items-center gap-2.5">
          <Button type="button" variant="outline" onClick={() => navigate("/admin/technicians/map")}>
            <MapPin className="size-4" />
            {t("dashboard.liveTracking")}
          </Button>
          <Button type="button" onClick={() => navigate("/admin/service")} className="shadow-[0_10px_20px_-12px_rgba(26,26,26,0.6)]">
            <Plus className="size-4" />
            {t("dashboard.assignJobs")}
          </Button>
        </div>
      </div>

      <div className="mb-4.5 grid grid-cols-1 gap-4.5 sm:grid-cols-3">
        <HighlightKpiCard
          label={t("dashboard.completedToday")}
          value={ticketsLoading ? "—" : completedToday}
          caption={t("common.today")}
          loading={ticketsLoading}
        />
        <KpiCard
          label={t("dashboard.openTickets")}
          loading={ticketsLoading}
          value={
            <div className="flex flex-col gap-2">
              <span className="text-[31px] font-extrabold leading-none tracking-tight tabular-nums text-text">{openTickets.length}</span>
              <span className="w-fit rounded-full bg-[#FCF1DF] px-2.5 py-1 text-xs font-bold text-warning">{urgentOpen.length} {t("dashboard.urgent")}</span>
            </div>
          }
        />
        <KpiCard
          label={t("dashboard.onDutyTechs")}
          loading={attendanceLoading}
          value={
            <div className="flex flex-col gap-2">
              <span className="text-[31px] font-extrabold leading-none tracking-tight tabular-nums text-text">
                {onDuty} <span className="text-[15px] font-semibold text-text-muted">/ {totalTechs}</span>
              </span>
              <span className="w-fit text-xs font-semibold text-text-muted">{absent} {t("dashboard.absentToday")}</span>
            </div>
          }
        />
      </div>

      <div className="grid grid-cols-1 gap-4.5 lg:grid-cols-[1.55fr_1fr]">
        <div className="overflow-hidden rounded-card border border-border bg-surface shadow-[0_1px_2px_rgba(26,26,26,.04),0_14px_30px_-22px_rgba(26,26,26,.16)]">
          <div className="px-5.5 pb-3 pt-4.5">
            <h3 className="text-[17px] font-bold tracking-tight text-text">{t("dashboard.todaysAppointments")}</h3>
          </div>
          <div className="grid grid-cols-[0.8fr_1.6fr_1.3fr_1fr] border-y border-border bg-surface-alt px-5.5 py-2.5">
            {[t("dashboard.tableTime"), t("dashboard.tableCustomer"), t("dashboard.tableTechnician"), t("dashboard.tableStatus")].map((h) => (
              <span key={h} className="text-[11px] font-semibold uppercase tracking-wide text-text-muted">
                {h}
              </span>
            ))}
          </div>
          {apptLoading ? (
            <p className="p-5.5 text-sm text-text-muted">{t("common.loading")}</p>
          ) : !appointments || appointments.length === 0 ? (
            <p className="p-5.5 text-sm text-text-muted">{t("dashboard.noAppointmentsToday")}</p>
          ) : (
            appointments.slice(0, 6).map((ap, i) => (
              <div key={ap.id} className={cn("grid grid-cols-[0.8fr_1.6fr_1.3fr_1fr] items-center px-5.5 py-3.25", i < Math.min(appointments.length, 6) - 1 && "border-b border-[#F1EDE6]")}>
                <span className="text-xs font-bold tabular-nums text-text">
                  {ap.scheduled_at ? new Date(ap.scheduled_at).toLocaleTimeString("en-IN", { hour: "2-digit", minute: "2-digit" }) : "—"}
                </span>
                <span className="text-[13px] font-semibold text-text">{ap.service_tickets?.customers?.name ?? "—"}</span>
                <span className="text-[13px] font-medium text-[#3A3A36]">{ap.technicians?.profiles?.full_name ?? t("dashboard.unassigned")}</span>
                <span className="flex items-center gap-1.5 text-xs font-semibold" style={{ color: APPT_STATUS_TONE[ap.status] ?? "var(--text-muted)" }}>
                  <span className="size-1.75 rounded-full" style={{ background: APPT_STATUS_TONE[ap.status] ?? "var(--text-muted)" }} />
                  {t(`service.appointmentStatus.${ap.status}`)}
                </span>
              </div>
            ))
          )}
        </div>

        <div className="flex flex-col gap-4.5">
          <div className="rounded-card border border-border bg-surface p-5.5 shadow-[0_1px_2px_rgba(26,26,26,.04),0_14px_30px_-22px_rgba(26,26,26,.16)]">
            <h3 className="mb-4 text-[17px] font-bold tracking-tight text-text">{t("dashboard.attendanceToday")}</h3>
            <div className="mb-4 flex items-center gap-4.5">
              <div
                className="relative size-24 shrink-0 rounded-full"
                style={{ background: attendanceLoading ? "#F0EBE3" : `conic-gradient(#2FAE5F 0 ${onTimePct}%, #E8932B ${onTimePct}% ${onTimePct + latePct}%, #E5484D ${onTimePct + latePct}% 100%)` }}
              >
                <div className="absolute inset-3.25 flex flex-col items-center justify-center rounded-full bg-surface">
                  <div className="text-[19px] font-extrabold tabular-nums text-text">
                    {onDuty}/{totalTechs}
                  </div>
                  <div className="text-[10px] font-medium text-text-muted">{t("dashboard.present")}</div>
                </div>
              </div>
              <div className="flex flex-1 flex-col gap-2.25 text-xs font-semibold text-text">
                <span className="flex items-center gap-1.75"><span className="size-2.25 rounded-[3px] bg-success" />{t("dashboard.onTime")} · {onTime}</span>
                <span className="flex items-center gap-1.75"><span className="size-2.25 rounded-[3px] bg-warning" />{t("dashboard.lateAfter")} · {late}</span>
                <span className="flex items-center gap-1.75"><span className="size-2.25 rounded-[3px] bg-danger" />{t("dashboard.absent")} · {absent}</span>
              </div>
            </div>
          </div>

          <div className="rounded-card border border-border bg-surface p-5 shadow-[0_1px_2px_rgba(26,26,26,.04),0_14px_30px_-22px_rgba(26,26,26,.16)]">
            <h3 className="mb-3.5 text-base font-bold tracking-tight text-text">{t("dashboard.escalations")}</h3>
            {overdueSlaLoading ? (
              <p className="text-sm text-text-muted">{t("common.loading")}</p>
            ) : !overdueSla || overdueSla.length === 0 ? (
              <p className="text-sm text-text-muted">{t("dashboard.noEscalations")}</p>
            ) : (
              <div className="flex flex-col gap-3">
                {overdueSla.slice(0, 3).map((tk) => (
                  <div key={tk.id} className="flex items-start gap-2.75">
                    <span className="flex size-7.5 shrink-0 items-center justify-center rounded-[9px] bg-[#FCEAEA] text-danger">
                      <TriangleAlert className="size-4" />
                    </span>
                    <div className="leading-tight">
                      <div className="text-[13px] font-semibold text-text">{tk.customers?.name ?? "—"}</div>
                      <div className="text-[11px] font-medium text-text-muted">
                        {tk.name_of_complaint ?? "—"} · {tk.products?.name ?? "—"}
                      </div>
                    </div>
                  </div>
                ))}
              </div>
            )}
          </div>
        </div>
      </div>
    </div>
  )
}
