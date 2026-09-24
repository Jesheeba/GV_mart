import { useMemo, useState } from "react"
import { useTranslation } from "react-i18next"
import { Loader2, PackageCheck, Plus, Trash2 } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Card } from "@/components/ui/card"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { DatePicker } from "@/components/ui/date-picker"
import { DataTable, type DataTableColumn } from "@/components/shared/DataTable"
import {
  useCreateSpareReturn,
  useSpareReturns,
  useTechnicianStock,
  useTechniciansList,
} from "@/hooks/useTechniciansAdmin"
import type { SpareReturnListItem } from "@/services/techniciansAdmin"

function todayIso() {
  return new Date().toISOString().slice(0, 10)
}

type DraftLine = { spareId: string; qtyReturned: string }

/**
 * Group 3 — mirrors TechniciansSpareHandoverPage's form shape (technician +
 * date + item lines + history table) exactly, but the spare dropdown is
 * constrained to what this technician's own `technician_stock_levels` ledger
 * says they currently hold (your "technician-item-picker" spec), instead of
 * handover's any-active-spare dropdown, and quantity is capped at their
 * held balance client-side — create_spare_return re-checks it server-side
 * regardless (see its migration's over-return test).
 */
export function TechniciansSpareReturnTab({ orgId }: { orgId: string | undefined }) {
  const { t } = useTranslation()
  const { data: returns, isLoading, isError, refetch } = useSpareReturns(orgId)
  const { data: technicians } = useTechniciansList(orgId)
  const createMut = useCreateSpareReturn()

  const [formOpen, setFormOpen] = useState(false)
  const [technicianId, setTechnicianId] = useState("")
  const [date, setDate] = useState(todayIso())
  const [lines, setLines] = useState<DraftLine[]>([{ spareId: "", qtyReturned: "" }])

  const holdings = useTechnicianStock(orgId, technicianId || undefined)
  const holdingsBySpare = useMemo(() => new Map((holdings.data ?? []).map((h) => [h.item_id, h])), [holdings.data])

  function addLine() {
    setLines((prev) => [...prev, { spareId: "", qtyReturned: "" }])
  }
  function removeLine(idx: number) {
    setLines((prev) => prev.filter((_, i) => i !== idx))
  }
  function updateLine(idx: number, patch: Partial<DraftLine>) {
    setLines((prev) => prev.map((l, i) => (i === idx ? { ...l, ...patch } : l)))
  }

  const validLines = useMemo(
    () =>
      lines
        .filter((l) => l.spareId && Number(l.qtyReturned) > 0 && Number(l.qtyReturned) <= (holdingsBySpare.get(l.spareId)?.stock_qty ?? 0))
        .map((l) => ({ spareId: l.spareId, qtyReturned: Number(l.qtyReturned) })),
    [lines, holdingsBySpare]
  )
  const canSubmit = !!orgId && !!technicianId && !!date && validLines.length > 0

  function resetForm() {
    setTechnicianId("")
    setDate(todayIso())
    setLines([{ spareId: "", qtyReturned: "" }])
    setFormOpen(false)
  }

  function submit() {
    if (!orgId || !canSubmit) return
    createMut.mutate({ orgId, technicianId, date, items: validLines }, { onSuccess: () => resetForm() })
  }

  const columns: DataTableColumn<SpareReturnListItem>[] = [
    { key: "date", header: t("technicians.spares.date"), render: (r) => new Date(r.date).toLocaleDateString("en-IN") },
    { key: "technician", header: t("technicians.spares.technician"), render: (r) => r.technicians?.profiles?.full_name ?? "—" },
    {
      key: "items",
      header: t("technicians.spares.itemsReturned"),
      render: (r) => (
        <span className="text-xs text-text-muted">
          {r.spare_return_items.length === 0 ? "—" : r.spare_return_items.map((i) => `${i.spares?.name ?? "?"} ×${i.qty_returned}`).join(", ")}
        </span>
      ),
    },
  ]

  return (
    <div className="space-y-4">
      <div className="flex flex-wrap items-start justify-end gap-3">
        <Button variant="accent" onClick={() => setFormOpen((v) => !v)}>
          <Plus className="size-4" />
          {t("technicians.spares.newReturn")}
        </Button>
      </div>

      {formOpen ? (
        <Card size="default" className="gap-3">
          <p className="text-sm font-semibold text-text">{t("technicians.spares.newReturn")}</p>
          <div className="grid grid-cols-1 gap-3 sm:grid-cols-2">
            <div className="space-y-1">
              <Label>{t("technicians.spares.technician")}</Label>
              <select
                value={technicianId}
                onChange={(e) => {
                  setTechnicianId(e.target.value)
                  setLines([{ spareId: "", qtyReturned: "" }])
                }}
                className="h-10 w-full rounded-xl border border-border bg-surface px-3 text-sm text-text outline-none"
              >
                <option value="">{t("technicians.spares.selectTechnician")}</option>
                {(technicians ?? []).map((tech) => (
                  <option key={tech.id} value={tech.id}>
                    {tech.profiles?.full_name ?? "—"}
                  </option>
                ))}
              </select>
            </div>
            <div className="space-y-1">
              <Label>{t("technicians.spares.date")}</Label>
              <DatePicker value={date} onChange={setDate} />
            </div>
          </div>

          {!technicianId ? (
            <p className="text-sm text-text-muted">{t("technicians.spares.selectTechnicianFirst")}</p>
          ) : holdings.isLoading ? (
            <p className="text-sm text-text-muted">{t("common.loading")}</p>
          ) : (holdings.data ?? []).length === 0 ? (
            <p className="text-sm text-text-muted">{t("technicians.spares.noHoldings")}</p>
          ) : (
            <div className="space-y-2">
              <Label>{t("technicians.spares.items")}</Label>
              {lines.map((line, idx) => {
                const held = holdingsBySpare.get(line.spareId)?.stock_qty
                return (
                  <div key={idx} className="flex items-center gap-2">
                    <select
                      value={line.spareId}
                      onChange={(e) => updateLine(idx, { spareId: e.target.value, qtyReturned: "" })}
                      className="h-10 flex-1 rounded-xl border border-border bg-surface px-3 text-sm text-text outline-none"
                    >
                      <option value="">{t("technicians.spares.selectSpare")}</option>
                      {(holdings.data ?? []).map((h) => (
                        <option key={h.item_id} value={h.item_id}>
                          {h.spares?.name ?? "?"} {h.spares?.sku ? `(${h.spares.sku})` : ""} — {h.stock_qty} {t("technicians.spares.held")}
                        </option>
                      ))}
                    </select>
                    <Input
                      type="number"
                      min={1}
                      max={held}
                      placeholder={t("technicians.spares.qty")}
                      value={line.qtyReturned}
                      onChange={(e) => updateLine(idx, { qtyReturned: e.target.value })}
                      className="w-28"
                    />
                    <Button size="icon-xs" variant="ghost" onClick={() => removeLine(idx)} disabled={lines.length === 1}>
                      <Trash2 className="size-3.5 text-danger" />
                    </Button>
                  </div>
                )
              })}
              <Button size="xs" variant="outline" onClick={addLine}>
                <Plus className="size-3.5" />
                {t("technicians.spares.addLine")}
              </Button>
            </div>
          )}

          {createMut.error ? (
            <p className="rounded-xl bg-danger/10 px-3.5 py-2.5 text-sm text-danger">{(createMut.error as Error).message}</p>
          ) : null}

          <div className="flex justify-end gap-2">
            <Button size="sm" variant="ghost" onClick={resetForm}>
              {t("common.cancel")}
            </Button>
            <Button size="sm" onClick={submit} disabled={!canSubmit || createMut.isPending}>
              {createMut.isPending ? <Loader2 className="size-3.5 animate-spin" /> : t("common.save")}
            </Button>
          </div>
        </Card>
      ) : null}

      <Card size="default">
        <div className="mb-2 flex items-center gap-2 px-1">
          <PackageCheck className="size-4 text-text-muted" />
          <p className="text-sm font-semibold text-text">{t("technicians.spares.returnHistoryTitle")}</p>
        </div>
        <DataTable
          columns={columns}
          rows={returns ?? []}
          rowKey={(r) => r.id}
          loading={isLoading}
          error={isError ? t("technicians.spares.returnLoadFailed") : null}
          onRetry={() => refetch()}
          emptyMessage={t("technicians.spares.returnEmpty")}
        />
      </Card>
    </div>
  )
}
