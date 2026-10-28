import { useState } from "react"
import { useTranslation } from "react-i18next"
import { Button } from "@/components/ui/button"
import { Card } from "@/components/ui/card"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { DatePicker } from "@/components/ui/date-picker"
import { PeriodFilter } from "@/app/admin/reports/PeriodFilter"
import { periodToRange, type PeriodValue } from "@/services/reports"
import { useProfile } from "@/hooks/useProfile"
import { useTechniciansList } from "@/hooks/useTechniciansAdmin"
import { useAddKmLogEntry, useApproxDistanceKm, useKmLogEntries, useKmLogMonthlySum } from "@/hooks/useMonthlyExpenses"

/** Monthly Expenses spec Unit 2 — kilometre log, admin side. Reuses
 *  PeriodFilter/periodToRange exactly as every report tab does (confirmed
 *  dependency-free of any admin-only coupling). */
export function KmLogTab() {
  const { t } = useTranslation()
  const { data: profile } = useProfile()
  const technicians = useTechniciansList(profile?.org_id)
  const [technicianId, setTechnicianId] = useState<string | null>(null)
  const [period, setPeriod] = useState<PeriodValue>({ mode: "month", month: new Date().toISOString().slice(0, 7) })
  const range = periodToRange(period)
  const periodMonth = "month" in period ? `${period.month}-01` : range.from

  const entries = useKmLogEntries(technicianId ?? undefined, range)
  const monthlySum = useKmLogMonthlySum(profile?.org_id, technicianId ?? undefined, periodMonth)
  const approx = useApproxDistanceKm(profile?.org_id, technicianId ?? undefined, periodMonth)
  const addEntry = useAddKmLogEntry()

  const [entryDate, setEntryDate] = useState("")
  const [km, setKm] = useState("")
  const [note, setNote] = useState("")

  async function submit() {
    if (!profile?.org_id || !technicianId || !entryDate || !km) return
    await addEntry.mutateAsync({ org_id: profile.org_id, technician_id: technicianId, entry_date: entryDate, km: Number(km), note: note.trim() || null })
    setEntryDate("")
    setKm("")
    setNote("")
  }

  return (
    <div className="space-y-3">
      <div className="space-y-1">
        <Label htmlFor="km-technician">{t("expenses.kmLog.technician")}</Label>
        <select
          id="km-technician"
          value={technicianId ?? ""}
          onChange={(e) => setTechnicianId(e.target.value || null)}
          className="h-11 w-full rounded-xl border border-border bg-surface px-3 text-sm text-text outline-none"
        >
          <option value="">{t("expenses.kmLog.selectTechnician")}</option>
          {(technicians.data ?? []).map((tech) => (
            <option key={tech.id} value={tech.id}>
              {tech.profiles?.full_name ?? "—"}
            </option>
          ))}
        </select>
      </div>

      <PeriodFilter value={period} onChange={setPeriod} />

      {technicianId ? (
        <Card className="gap-1">
          <p className="text-sm text-text">{t("expenses.kmLog.monthlySum", { km: monthlySum.data ?? 0 })}</p>
          <p className="text-xs text-text-muted">{t("expenses.kmLog.approxReference", { km: approx.data ?? 0 })}</p>
        </Card>
      ) : null}

      {technicianId ? (
        <Card className="gap-2.5">
          <p className="text-sm font-semibold text-text">{t("expenses.kmLog.addEntry")}</p>
          <div className="grid grid-cols-2 gap-3 sm:grid-cols-3">
            <div className="space-y-1">
              <Label>{t("expenses.kmLog.entryDate")}</Label>
              <DatePicker value={entryDate} onChange={setEntryDate} />
            </div>
            <div className="space-y-1">
              <Label htmlFor="km-value">{t("expenses.kmLog.km")}</Label>
              <Input id="km-value" type="number" min={0} step="0.1" value={km} onChange={(e) => setKm(e.target.value)} />
            </div>
            <div className="space-y-1">
              <Label htmlFor="km-note">{t("expenses.kmLog.note")}</Label>
              <Input id="km-note" value={note} onChange={(e) => setNote(e.target.value)} />
            </div>
          </div>
          <Button type="button" size="sm" disabled={!entryDate || !km || addEntry.isPending} onClick={submit}>
            {t("expenses.kmLog.save")}
          </Button>
        </Card>
      ) : null}

      {technicianId ? (
        <div className="space-y-1.5">
          {(entries.data ?? []).length === 0 ? (
            <p className="text-sm text-text-muted">{t("expenses.kmLog.empty")}</p>
          ) : (
            entries.data!.map((entry) => (
              <Card key={entry.id} className="flex-row items-center justify-between gap-2 py-2">
                <span className="text-sm text-text">{entry.entry_date}</span>
                <span className="text-sm font-semibold text-text">{entry.km} km</span>
                {entry.note ? <span className="truncate text-xs text-text-muted">{entry.note}</span> : null}
              </Card>
            ))
          )}
        </div>
      ) : null}
    </div>
  )
}
