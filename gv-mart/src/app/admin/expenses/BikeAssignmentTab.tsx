import { useState } from "react"
import { useTranslation } from "react-i18next"
import { Bike } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Card } from "@/components/ui/card"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { DatePicker } from "@/components/ui/date-picker"
import { useProfile } from "@/hooks/useProfile"
import { useTechniciansList } from "@/hooks/useTechniciansAdmin"
import {
  useCloseTechnicianVehicleRow,
  useSetTechnicianVehicle,
  useTechnicianVehicleHistory,
} from "@/hooks/useMonthlyExpenses"

/**
 * Monthly Expenses spec Unit 1 — bike ownership + petrol rate, effective-
 * dated. Same inline-Card-with-local-state convention as
 * TechnicianDetailPage.tsx's AvailabilityTab, not a Dialog.
 */
export function BikeAssignmentTab() {
  const { t } = useTranslation()
  const { data: profile } = useProfile()
  const technicians = useTechniciansList(profile?.org_id)
  const [selectedId, setSelectedId] = useState<string | null>(null)

  return (
    <div className="space-y-3">
      <p className="text-sm text-text-muted">{t("expenses.bikeAssignment.hint")}</p>
      <div className="space-y-2">
        {(technicians.data ?? []).map((tech) => (
          <Card key={tech.id} className="gap-2">
            <button
              type="button"
              className="flex w-full items-center justify-between gap-2 px-4 text-left"
              onClick={() => setSelectedId(selectedId === tech.id ? null : tech.id)}
            >
              <span className="flex items-center gap-2 text-sm font-semibold text-text">
                <Bike className="size-4 text-text-muted" />
                {tech.profiles?.full_name ?? "—"}
              </span>
              <span className="text-xs text-text-muted">{t("common.tapToExpand")}</span>
            </button>
            {selectedId === tech.id ? <BikeAssignmentForm orgId={profile?.org_id} technicianId={tech.id} /> : null}
          </Card>
        ))}
      </div>
    </div>
  )
}

function BikeAssignmentForm({ orgId, technicianId }: { orgId: string | undefined; technicianId: string }) {
  const { t } = useTranslation()
  const history = useTechnicianVehicleHistory(technicianId)
  const setVehicle = useSetTechnicianVehicle()
  const closeRow = useCloseTechnicianVehicleRow()

  const [ownership, setOwnership] = useState<"own" | "company">("own")
  const [rate, setRate] = useState("0")
  const [effectiveFrom, setEffectiveFrom] = useState("")
  const [error, setError] = useState<string | null>(null)

  const current = (history.data ?? []).find((r) => !r.effective_to)

  async function submit() {
    if (!orgId || !effectiveFrom) return
    setError(null)
    try {
      // End the currently-open row the day before the new one starts, so the
      // two never overlap (the database rejects an overlap either way).
      if (current) {
        const prevDay = new Date(effectiveFrom)
        prevDay.setDate(prevDay.getDate() - 1)
        await closeRow.mutateAsync({ id: current.id, effectiveTo: prevDay.toISOString().slice(0, 10), technicianId })
      }
      await setVehicle.mutateAsync({
        org_id: orgId,
        technician_id: technicianId,
        ownership,
        petrol_rate_per_km: Number(rate),
        effective_from: effectiveFrom,
      })
      setEffectiveFrom("")
    } catch (e) {
      setError((e as Error).message)
    }
  }

  return (
    <div className="space-y-3 border-t border-border px-4 pt-3">
      {current ? (
        <p className="text-xs text-text-muted">
          {t("expenses.bikeAssignment.current", {
            ownership: t(`expenses.bikeAssignment.ownershipValues.${current.ownership}`),
            rate: current.petrol_rate_per_km,
          })}
        </p>
      ) : (
        <p className="text-xs text-text-muted">{t("expenses.bikeAssignment.noRow")}</p>
      )}

      <div className="grid grid-cols-2 gap-3 sm:grid-cols-3">
        <div className="space-y-1">
          <Label htmlFor={`ownership-${technicianId}`}>{t("expenses.bikeAssignment.ownership")}</Label>
          <select
            id={`ownership-${technicianId}`}
            value={ownership}
            onChange={(e) => setOwnership(e.target.value as "own" | "company")}
            className="h-11 w-full rounded-xl border border-border bg-surface px-3 text-sm text-text outline-none"
          >
            <option value="own">{t("expenses.bikeAssignment.ownershipValues.own")}</option>
            <option value="company">{t("expenses.bikeAssignment.ownershipValues.company")}</option>
          </select>
        </div>
        <div className="space-y-1">
          <Label htmlFor={`rate-${technicianId}`}>{t("expenses.bikeAssignment.rate")}</Label>
          <Input id={`rate-${technicianId}`} type="number" min={0} step="0.5" value={rate} onChange={(e) => setRate(e.target.value)} />
        </div>
        <div className="space-y-1">
          <Label>{t("expenses.bikeAssignment.effectiveFrom")}</Label>
          <DatePicker value={effectiveFrom} onChange={setEffectiveFrom} />
        </div>
      </div>

      <Button
        type="button"
        size="sm"
        disabled={!orgId || !effectiveFrom || setVehicle.isPending || closeRow.isPending}
        onClick={submit}
      >
        {t("expenses.bikeAssignment.save")}
      </Button>
      {error ? <p className="text-xs text-danger">{error}</p> : null}

      {(history.data ?? []).length > 0 ? (
        <div className="space-y-1">
          <p className="text-xs font-semibold text-text-muted">{t("expenses.bikeAssignment.history")}</p>
          {(history.data ?? []).map((row) => (
            <p key={row.id} className="text-xs text-text-muted">
              {row.effective_from} → {row.effective_to ?? t("common.ongoing")}: {t(`expenses.bikeAssignment.ownershipValues.${row.ownership}`)}, ₹{row.petrol_rate_per_km}/km
            </p>
          ))}
        </div>
      ) : null}
    </div>
  )
}
