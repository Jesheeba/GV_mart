import { useMemo, useState } from "react"
import { useTranslation } from "react-i18next"
import { Loader2, PackageOpen, Plus, Trash2 } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Card } from "@/components/ui/card"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { DataTable, type DataTableColumn } from "@/components/shared/DataTable"
import { StatusDot } from "@/components/shared/StatusDot"
import { SignaturePad } from "@/app/technician/components/SignaturePad"
import { useProfile } from "@/hooks/useProfile"
import {
  useAdminSignSpareHandover,
  useCreateSpareHandover,
  useSpareHandovers,
  useSparesForHandover,
} from "@/hooks/useTechniciansAdmin"
import { useTechniciansList } from "@/hooks/useTechniciansAdmin"
import type { SpareHandoverListItem } from "@/services/techniciansAdmin"

function todayIso() {
  return new Date().toISOString().slice(0, 10)
}

type DraftLine = { spareId: string; qtyGiven: string }

/**
 * ADM-17. "Allocation based on yesterday's cumulative invoices" (ENHANCE
 * tier auto-suggest) is skipped — this builds the APPEARS-level manual
 * quantity entry form plus dual-sign + history log.
 */
export function TechniciansSpareHandoverPage() {
  const { t } = useTranslation()
  const { data: profile } = useProfile()
  const orgId = profile?.org_id

  const { data: handovers, isLoading, isError, refetch } = useSpareHandovers(orgId)
  const { data: technicians } = useTechniciansList(orgId)
  const { data: spares } = useSparesForHandover(orgId)
  const createMut = useCreateSpareHandover()
  const adminSignMut = useAdminSignSpareHandover()

  const [formOpen, setFormOpen] = useState(false)
  const [technicianId, setTechnicianId] = useState("")
  const [date, setDate] = useState(todayIso())
  const [lines, setLines] = useState<DraftLine[]>([{ spareId: "", qtyGiven: "" }])
  const [signingId, setSigningId] = useState<string | null>(null)
  const [adminSign, setAdminSign] = useState<string | null>(null)

  function addLine() {
    setLines((prev) => [...prev, { spareId: "", qtyGiven: "" }])
  }
  function removeLine(idx: number) {
    setLines((prev) => prev.filter((_, i) => i !== idx))
  }
  function updateLine(idx: number, patch: Partial<DraftLine>) {
    setLines((prev) => prev.map((l, i) => (i === idx ? { ...l, ...patch } : l)))
  }

  const validLines = useMemo(
    () => lines.filter((l) => l.spareId && Number(l.qtyGiven) > 0).map((l) => ({ spareId: l.spareId, qtyGiven: Number(l.qtyGiven) })),
    [lines]
  )
  const canSubmit = !!orgId && !!technicianId && !!date && validLines.length > 0

  function resetForm() {
    setTechnicianId("")
    setDate(todayIso())
    setLines([{ spareId: "", qtyGiven: "" }])
    setFormOpen(false)
  }

  function submit() {
    if (!orgId || !canSubmit) return
    createMut.mutate(
      { orgId, technicianId, date, items: validLines },
      { onSuccess: () => resetForm() }
    )
  }

  function submitAdminSign() {
    if (!signingId || !adminSign) return
    adminSignMut.mutate(
      { handoverId: signingId, adminSignUrl: adminSign },
      { onSuccess: () => { setSigningId(null); setAdminSign(null) } }
    )
  }

  const columns: DataTableColumn<SpareHandoverListItem>[] = [
    { key: "date", header: t("technicians.spares.date"), render: (r) => new Date(r.date).toLocaleDateString("en-IN") },
    { key: "technician", header: t("technicians.spares.technician"), render: (r) => r.technicians?.profiles?.full_name ?? "—" },
    {
      key: "items",
      header: t("technicians.spares.itemsGiven"),
      render: (r) => (
        <span className="text-xs text-text-muted">
          {r.spare_handover_items.length === 0
            ? "—"
            : r.spare_handover_items.map((i) => `${i.spares?.name ?? "?"} ×${i.qty_given}${i.qty_returned ? ` (${t("technicians.spares.returned")} ${i.qty_returned})` : ""}`).join(", ")}
        </span>
      ),
    },
    {
      key: "adminSign",
      header: t("technicians.spares.adminSign"),
      render: (r) =>
        r.admin_sign_url ? (
          <StatusDot tone="success" label={t("technicians.spares.signed")} />
        ) : (
          <Button size="xs" variant="outline" onClick={() => setSigningId(r.id)}>
            {t("technicians.spares.signNow")}
          </Button>
        ),
    },
    { key: "techSign", header: t("technicians.spares.techSign"), render: (r) => <StatusDot tone={r.tech_sign_url ? "success" : "neutral"} label={r.tech_sign_url ? t("technicians.spares.signed") : t("technicians.spares.pending")} /> },
    {
      key: "status",
      header: t("technicians.spares.status"),
      render: (r) => <StatusDot tone={r.status === "confirmed" ? "success" : "warning"} label={t(`technicians.spares.statusValues.${r.status}`)} />,
    },
  ]

  return (
    <div className="space-y-4 pt-2">
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <h1 className="text-2xl font-bold text-text">{t("technicians.spares.title")}</h1>
          <p className="text-sm text-text-muted">{t("technicians.spares.subtitle")}</p>
        </div>
        <Button variant="accent" onClick={() => setFormOpen((v) => !v)}>
          <Plus className="size-4" />
          {t("technicians.spares.newHandover")}
        </Button>
      </div>

      {formOpen ? (
        <Card size="default" className="gap-3">
          <p className="text-sm font-semibold text-text">{t("technicians.spares.newHandover")}</p>
          <div className="grid grid-cols-1 gap-3 sm:grid-cols-2">
            <div className="space-y-1">
              <Label>{t("technicians.spares.technician")}</Label>
              <select
                value={technicianId}
                onChange={(e) => setTechnicianId(e.target.value)}
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
              <Input type="date" value={date} onChange={(e) => setDate(e.target.value)} />
            </div>
          </div>

          <div className="space-y-2">
            <Label>{t("technicians.spares.items")}</Label>
            {lines.map((line, idx) => (
              <div key={idx} className="flex items-center gap-2">
                <select
                  value={line.spareId}
                  onChange={(e) => updateLine(idx, { spareId: e.target.value })}
                  className="h-10 flex-1 rounded-xl border border-border bg-surface px-3 text-sm text-text outline-none"
                >
                  <option value="">{t("technicians.spares.selectSpare")}</option>
                  {(spares ?? []).map((s) => (
                    <option key={s.id} value={s.id}>
                      {s.name} {s.sku ? `(${s.sku})` : ""}
                    </option>
                  ))}
                </select>
                <Input
                  type="number"
                  min={1}
                  placeholder={t("technicians.spares.qty")}
                  value={line.qtyGiven}
                  onChange={(e) => updateLine(idx, { qtyGiven: e.target.value })}
                  className="w-28"
                />
                <Button size="icon-xs" variant="ghost" onClick={() => removeLine(idx)} disabled={lines.length === 1}>
                  <Trash2 className="size-3.5 text-danger" />
                </Button>
              </div>
            ))}
            <Button size="xs" variant="outline" onClick={addLine}>
              <Plus className="size-3.5" />
              {t("technicians.spares.addLine")}
            </Button>
          </div>

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

      {signingId ? (
        <Card size="default" className="gap-3">
          <p className="text-sm font-semibold text-text">{t("technicians.spares.adminSignTitle")}</p>
          <SignaturePad onChange={setAdminSign} disabled={adminSignMut.isPending} />
          <div className="flex justify-end gap-2">
            <Button size="sm" variant="ghost" onClick={() => { setSigningId(null); setAdminSign(null) }}>
              {t("common.cancel")}
            </Button>
            <Button size="sm" onClick={submitAdminSign} disabled={!adminSign || adminSignMut.isPending}>
              {adminSignMut.isPending ? <Loader2 className="size-3.5 animate-spin" /> : t("technicians.spares.signNow")}
            </Button>
          </div>
        </Card>
      ) : null}

      <Card size="default">
        <div className="mb-2 flex items-center gap-2 px-1">
          <PackageOpen className="size-4 text-text-muted" />
          <p className="text-sm font-semibold text-text">{t("technicians.spares.historyTitle")}</p>
        </div>
        <DataTable
          columns={columns}
          rows={handovers ?? []}
          rowKey={(r) => r.id}
          loading={isLoading}
          error={isError ? t("technicians.spares.loadFailed") : null}
          onRetry={() => refetch()}
          emptyMessage={t("technicians.spares.empty")}
        />
      </Card>
    </div>
  )
}
