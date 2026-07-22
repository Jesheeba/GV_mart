import { useState } from "react"
import { useTranslation } from "react-i18next"
import { Loader2, Plus, ShieldOff, Trash2 } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { useAddExemptionWindow, useRemoveExemptionWindow, useSetExemptionWindowActive } from "@/hooks/useCustomers"
import type { ExemptionWindowRow } from "@/services/customers"

const DAYS = [0, 1, 2, 3, 4, 5, 6] as const

/**
 * B4 (Build Order Step 4, Meeting spec Section B4) — SCOPE-GUARD, authorized:
 * per-customer short recurring "never assign a technician here" windows
 * (school run, medical). Renders bare (no outer Card), same convention as
 * FamilyMembersPanel, so it drops cleanly into CustomerDetailPage's
 * Exemptions tab.
 */
export function ExemptionWindowsPanel({
  orgId,
  customerId,
  windows,
}: {
  orgId: string | undefined
  customerId: string
  windows: ExemptionWindowRow[]
}) {
  const { t } = useTranslation()
  const [showAddForm, setShowAddForm] = useState(false)
  const [label, setLabel] = useState("")
  const [dayOfWeek, setDayOfWeek] = useState<string>("")
  const [startTime, setStartTime] = useState("")
  const [endTime, setEndTime] = useState("")
  const [formError, setFormError] = useState("")
  const [confirmingRemove, setConfirmingRemove] = useState<string | null>(null)

  const addWindow = useAddExemptionWindow(orgId, customerId)
  const removeWindow = useRemoveExemptionWindow(customerId)
  const setActive = useSetExemptionWindowActive(customerId)

  function resetForm() {
    setLabel("")
    setDayOfWeek("")
    setStartTime("")
    setEndTime("")
    setFormError("")
  }

  function onAdd() {
    setFormError("")
    if (!label.trim() || !startTime || !endTime) return
    if (startTime >= endTime) {
      setFormError(t("customers.detail.exemptionsPanel.invalidRange"))
      return
    }
    addWindow.mutate(
      { label: label.trim(), dayOfWeek: dayOfWeek === "" ? null : Number(dayOfWeek), startTime, endTime },
      { onSuccess: () => { resetForm(); setShowAddForm(false) } }
    )
  }

  return (
    <div className="space-y-3.5">
      <div className="flex items-center justify-between px-1">
        <h2 className="text-lg font-semibold text-text">{t("customers.detail.exemptionsPanel.title", { count: windows.length })}</h2>
        <Button size="sm" variant="outline" onClick={() => setShowAddForm((v) => !v)}>
          <Plus className="size-3.5" />
          {t("customers.detail.exemptionsPanel.add")}
        </Button>
      </div>

      <p className="px-1 text-xs text-text-muted">{t("customers.detail.exemptionsPanel.hint")}</p>

      {windows.length === 0 ? (
        <p className="px-1 text-sm text-text-muted">{t("customers.detail.exemptionsPanel.empty")}</p>
      ) : (
        <div className="grid grid-cols-1 gap-3 px-1 sm:grid-cols-2">
          {windows.map((w) => (
            <div key={w.id} className={`flex items-start gap-3 rounded-[18px] border p-4 ${w.is_active ? "border-danger/30 bg-danger/5" : "border-border bg-surface opacity-60"}`}>
              <span className="flex size-9 shrink-0 items-center justify-center rounded-[12px] bg-danger/15 text-danger">
                <ShieldOff className="size-4" />
              </span>
              <div className="min-w-0 flex-1">
                <div className="truncate text-sm font-bold text-text">{w.label}</div>
                <div className="text-xs text-text-muted">
                  {w.day_of_week === null ? t("customers.detail.exemptionsPanel.everyDay") : t(`customers.detail.exemptionsPanel.days.${w.day_of_week}`)}
                  {" · "}
                  {w.start_time.slice(0, 5)}–{w.end_time.slice(0, 5)}
                </div>
                <div className="mt-1.5 flex flex-wrap items-center gap-x-2.5 gap-y-1 text-xs">
                  <button
                    type="button"
                    className="font-semibold text-text-muted hover:text-text disabled:opacity-50"
                    disabled={setActive.isPending}
                    onClick={() => setActive.mutate({ id: w.id, isActive: !w.is_active })}
                  >
                    {w.is_active ? t("customers.detail.exemptionsPanel.deactivate") : t("customers.detail.exemptionsPanel.activate")}
                  </button>
                  {confirmingRemove !== w.id ? (
                    <button type="button" className="flex items-center gap-1 font-semibold text-danger hover:underline" onClick={() => setConfirmingRemove(w.id)}>
                      <Trash2 className="size-3" />
                    </button>
                  ) : (
                    <span className="flex items-center gap-1.5">
                      <button
                        type="button"
                        className="font-semibold text-danger hover:underline"
                        disabled={removeWindow.isPending}
                        onClick={() => removeWindow.mutate(w.id, { onSuccess: () => setConfirmingRemove(null) })}
                      >
                        {removeWindow.isPending ? <Loader2 className="size-3 animate-spin" /> : t("customers.detail.confirm")}
                      </button>
                      <button type="button" className="text-text-muted hover:underline" onClick={() => setConfirmingRemove(null)}>
                        {t("common.cancel")}
                      </button>
                    </span>
                  )}
                </div>
              </div>
            </div>
          ))}
        </div>
      )}

      {showAddForm ? (
        <div className="space-y-2 border-t border-border px-1 pt-3.5">
          <div className="flex gap-2">
            <div className="flex-1 space-y-1">
              <Label>{t("customers.detail.exemptionsPanel.label")}</Label>
              <Input value={label} onChange={(e) => setLabel(e.target.value)} placeholder={t("customers.detail.exemptionsPanel.labelPlaceholder")} />
            </div>
            <div className="flex-1 space-y-1">
              <Label>{t("customers.detail.exemptionsPanel.dayOfWeek")}</Label>
              <select
                value={dayOfWeek}
                onChange={(e) => setDayOfWeek(e.target.value)}
                className="h-10 w-full rounded-xl border border-border bg-surface px-3 text-sm text-text outline-none"
              >
                <option value="">{t("customers.detail.exemptionsPanel.everyDay")}</option>
                {DAYS.map((d) => (
                  <option key={d} value={d}>
                    {t(`customers.detail.exemptionsPanel.days.${d}`)}
                  </option>
                ))}
              </select>
            </div>
          </div>
          <div className="flex gap-2">
            <div className="flex-1 space-y-1">
              <Label>{t("customers.detail.exemptionsPanel.startTime")}</Label>
              <Input type="time" value={startTime} onChange={(e) => setStartTime(e.target.value)} />
            </div>
            <div className="flex-1 space-y-1">
              <Label>{t("customers.detail.exemptionsPanel.endTime")}</Label>
              <Input type="time" value={endTime} onChange={(e) => setEndTime(e.target.value)} />
            </div>
          </div>
          {formError ? <p className="text-xs text-danger">{formError}</p> : null}
          {addWindow.isError ? <p className="text-xs text-danger">{(addWindow.error as Error).message}</p> : null}
          <div className="flex justify-end gap-2">
            <Button type="button" size="sm" variant="ghost" onClick={() => setShowAddForm(false)}>
              {t("common.cancel")}
            </Button>
            <Button type="button" size="sm" disabled={addWindow.isPending || !label.trim() || !startTime || !endTime} onClick={onAdd}>
              {addWindow.isPending ? <Loader2 className="size-3.5 animate-spin" /> : t("common.save")}
            </Button>
          </div>
        </div>
      ) : null}
    </div>
  )
}
