import { useEffect, useState } from "react"
import { useTranslation } from "react-i18next"
import { Check, X } from "lucide-react"
import { Card } from "@/components/ui/card"
import { DatePicker } from "@/components/ui/date-picker"
import { Label } from "@/components/ui/label"
import { DataTable, type DataTableColumn } from "@/components/shared/DataTable"
import { StatusDot } from "@/components/shared/StatusDot"
import { useProfile } from "@/hooks/useProfile"
import { useAttendanceForDate } from "@/hooks/useTechniciansAdmin"
import { useSettings } from "@/hooks/useMasters"
import type { AttendanceListItem } from "@/services/techniciansAdmin"
import { ATTENDANCE_STATUS_I18N_KEY, ATTENDANCE_STATUS_TONE } from "@/lib/attendance-status"

function todayIso() {
  return new Date().toISOString().slice(0, 10)
}

function lunchMinutes(r: AttendanceListItem, now: number) {
  if (!r.lunch_start) return null
  const endMs = r.lunch_end ? new Date(r.lunch_end).getTime() : now
  return Math.round((endMs - new Date(r.lunch_start).getTime()) / 60_000)
}

function Tick({ ok }: { ok: boolean }) {
  return ok ? <Check className="size-4 text-success" /> : <X className="size-4 text-text-muted" />
}

/**
 * ADM-16. Read/filter only — the technician submits attendance from their
 * own app (src/app/technician/AttendancePage.tsx) already; no admin edit or
 * regularization flow is built here per the build brief's scope.
 */
export function TechniciansAttendancePage() {
  const { t } = useTranslation()
  const { data: profile } = useProfile()
  const orgId = profile?.org_id
  const [date, setDate] = useState(todayIso())

  const { data: rows, isLoading, isError, refetch } = useAttendanceForDate(orgId, date)
  const { data: settings } = useSettings(orgId)
  const lunchRedMin = settings?.lunch_minutes_red_threshold ?? 45

  const [now, setNow] = useState(() => Date.now())
  const hasOngoingLunch = (rows ?? []).some((r) => r.lunch_start && !r.lunch_end)

  useEffect(() => {
    if (!hasOngoingLunch) return
    const id = setInterval(() => setNow(Date.now()), 30_000)
    return () => clearInterval(id)
  }, [hasOngoingLunch])

  const columns: DataTableColumn<AttendanceListItem>[] = [
    { key: "technician", header: t("technicians.attendance.technician"), render: (r) => r.technicians?.profiles?.full_name ?? "—" },
    {
      key: "checkIn",
      header: t("technicians.attendance.checkInTime"),
      render: (r) => (r.check_in_at ? new Date(r.check_in_at).toLocaleTimeString("en-IN", { hour: "2-digit", minute: "2-digit" }) : "—"),
    },
    { key: "geofence", header: t("technicians.attendance.insideGeofence"), render: (r) => <Tick ok={r.inside_geofence} /> },
    { key: "affirmation", header: t("technicians.attendance.affirmation"), render: (r) => <Tick ok={r.affirmation} /> },
    { key: "pledge", header: t("technicians.attendance.pledge"), render: (r) => <Tick ok={r.pledge} /> },
    { key: "meeting", header: t("technicians.attendance.meeting"), render: (r) => <Tick ok={r.meeting} /> },
    {
      key: "lunch",
      header: t("technicians.attendance.lunch"),
      render: (r) => {
        const mins = lunchMinutes(r, now)
        if (mins === null) return "—"
        return <span className={mins > lunchRedMin ? "font-medium text-danger" : "text-text"}>{t("technicians.attendance.lunchMinutes", { minutes: mins })}</span>
      },
    },
    {
      key: "late",
      header: t("technicians.attendance.late"),
      render: (r) => (r.check_in_at ? <StatusDot tone={ATTENDANCE_STATUS_TONE[r.status]} label={t(ATTENDANCE_STATUS_I18N_KEY[r.status])} /> : "—"),
    },
  ]

  return (
    <div className="space-y-4 pt-2">
      <div>
        <h1 className="text-2xl font-bold text-text">{t("technicians.attendance.title")}</h1>
        <p className="text-sm text-text-muted">{t("technicians.attendance.subtitle")}</p>
      </div>

      <Card size="default" className="gap-3">
        <div className="flex items-center gap-2">
          <Label htmlFor="attendance-date" className="text-sm">
            {t("technicians.attendance.date")}
          </Label>
          <DatePicker id="attendance-date" value={date} onChange={setDate} className="max-w-48" />
        </div>

        <DataTable
          columns={columns}
          rows={rows ?? []}
          rowKey={(r) => r.id}
          loading={isLoading}
          error={isError ? t("technicians.attendance.loadFailed") : null}
          onRetry={() => refetch()}
          emptyMessage={t("technicians.attendance.empty")}
        />
      </Card>
    </div>
  )
}
