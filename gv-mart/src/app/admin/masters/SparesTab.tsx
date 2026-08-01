import { useMemo, useState } from "react"
import { useTranslation } from "react-i18next"
import { Loader2, Upload } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { EntityCrudTable, type CrudFieldDef } from "@/components/shared/EntityCrudTable"
import { sparesHooks, useBulkSetSparesActive } from "@/hooks/useMasters"
import type { SpareRow } from "@/services/masters"
import { useProfile } from "@/hooks/useProfile"
import { SpareBulkImportPanel } from "./SpareBulkImportPanel"

type StatusFilter = "all" | "active" | "inactive"

export function SparesTab() {
  const { t } = useTranslation()
  const { data: profile } = useProfile()
  const orgId = profile?.org_id

  const { data: rows, isLoading, isError, refetch } = sparesHooks.useList(orgId)
  const createMut = sparesHooks.useCreate()
  const updateMut = sparesHooks.useUpdate()
  const deleteMut = sparesHooks.useDelete()
  const bulkSetActive = useBulkSetSparesActive()

  // Task 6 (2026-07-30) — search/filter/bulk-select/bulk-import/enable-
  // disable. All client-side over the org's already-fetched spares list
  // (same pattern as the admin Tickets filter bar) — this is a masters
  // list, not paginated data.
  const [search, setSearch] = useState("")
  const [statusFilter, setStatusFilter] = useState<StatusFilter>("all")
  const [selectedIds, setSelectedIds] = useState<Set<string>>(new Set())
  const [importOpen, setImportOpen] = useState(false)

  const filteredRows = useMemo(() => {
    const term = search.trim().toLowerCase()
    return ((rows ?? []) as SpareRow[]).filter((r) => {
      if (statusFilter === "active" && !r.is_active) return false
      if (statusFilter === "inactive" && r.is_active) return false
      if (term && !r.name.toLowerCase().includes(term) && !(r.sku ?? "").toLowerCase().includes(term)) return false
      return true
    })
  }, [rows, search, statusFilter])

  function toggleSelect(id: string) {
    setSelectedIds((prev) => {
      const next = new Set(prev)
      if (next.has(id)) next.delete(id)
      else next.add(id)
      return next
    })
  }
  const allFilteredSelected = filteredRows.length > 0 && filteredRows.every((r) => selectedIds.has(r.id))
  function toggleSelectAll() {
    setSelectedIds((prev) => {
      const next = new Set(prev)
      if (allFilteredSelected) filteredRows.forEach((r) => next.delete(r.id))
      else filteredRows.forEach((r) => next.add(r.id))
      return next
    })
  }
  async function handleBulkSetActive(isActive: boolean) {
    await bulkSetActive.mutateAsync({ ids: [...selectedIds], isActive })
    setSelectedIds(new Set())
  }

  const fields: CrudFieldDef[] = [
    { key: "name", label: t("masters.spares.name"), type: "text", required: true },
    { key: "sku", label: t("masters.spares.sku"), type: "text", pattern: "[A-Za-z0-9_-]+", patternMessage: t("masters.errors.skuInvalid") },
    { key: "price", label: t("masters.spares.price"), type: "number", step: "0.01", required: true, min: 0 },
    { key: "cost_price", label: t("masters.spares.costPrice"), type: "number", step: "0.01", placeholder: t("masters.costPriceNotSet"), min: 0 },
    { key: "hsn_code", label: t("masters.spares.hsn"), type: "text", pattern: "\\d{4,8}", patternMessage: t("masters.errors.hsnInvalid") },
    // GV.md 1.1: "back wheel 10 min, horn 5 min, tank clean 5 min" — the
    // admin-set standard service time that feeds the SOP checklist (1.1/D4)
    // and the technician's estimated/allowed time (1.2). Blank = not timed
    // yet. operation_admin edits the same column from Inventory (see
    // InventoryTable.tsx) via the narrower set_item_standard_time RPC, since
    // this whole tab is master-only per RLS.
    { key: "standard_time_minutes", label: t("masters.spares.standardTime"), type: "number", step: "1", min: 0 },
  ]

  return (
    <div className="space-y-3">
      <div className="flex flex-wrap items-center gap-2">
        <Input value={search} onChange={(e) => setSearch(e.target.value)} placeholder={t("masters.spares.searchPlaceholder")} className="max-w-xs" />
        <select
          value={statusFilter}
          onChange={(e) => setStatusFilter(e.target.value as StatusFilter)}
          className="h-10 rounded-xl border border-border bg-surface px-3 text-sm text-text outline-none"
        >
          <option value="all">{t("masters.spares.filterAll")}</option>
          <option value="active">{t("masters.spares.filterActive")}</option>
          <option value="inactive">{t("masters.spares.filterInactive")}</option>
        </select>
        <Button size="sm" variant="outline" className="ml-auto gap-1.5" onClick={() => setImportOpen(true)}>
          <Upload className="size-3.5" />
          {t("masters.spares.bulkImport")}
        </Button>
      </div>

      {selectedIds.size > 0 ? (
        <div className="flex flex-wrap items-center gap-2 rounded-xl border border-border bg-surface-alt px-3.5 py-2.5">
          <span className="text-xs font-medium text-text">{t("masters.spares.selectedCount", { count: selectedIds.size })}</span>
          <Button size="sm" variant="outline" disabled={bulkSetActive.isPending} onClick={() => handleBulkSetActive(true)}>
            {bulkSetActive.isPending ? <Loader2 className="size-3.5 animate-spin" /> : t("masters.spares.bulkEnable")}
          </Button>
          <Button size="sm" variant="outline" disabled={bulkSetActive.isPending} onClick={() => handleBulkSetActive(false)}>
            {bulkSetActive.isPending ? <Loader2 className="size-3.5 animate-spin" /> : t("masters.spares.bulkDisable")}
          </Button>
          <Button size="sm" variant="ghost" onClick={() => setSelectedIds(new Set())}>
            {t("masters.spares.clearSelection")}
          </Button>
        </div>
      ) : null}

      <EntityCrudTable<SpareRow>
        fields={fields}
        rows={filteredRows}
        getId={(r) => r.id}
        loading={isLoading}
        error={isError ? t("masters.loadFailed") : null}
        onRetry={() => refetch()}
        isMutating={createMut.isPending || updateMut.isPending}
        addLabel={t("masters.spares.add")}
        emptyMessage={search || statusFilter !== "all" ? t("masters.spares.noResults") : t("masters.spares.empty")}
        toFormValues={(r) => ({
          name: r.name,
          sku: r.sku ?? "",
          price: String(r.price),
          cost_price: r.cost_price != null ? String(r.cost_price) : "",
          hsn_code: r.hsn_code ?? "",
          standard_time_minutes: r.standard_time_minutes != null ? String(r.standard_time_minutes) : "",
        })}
        columns={[
          {
            key: "__select",
            header: <input type="checkbox" checked={allFilteredSelected} onChange={toggleSelectAll} aria-label={t("masters.spares.selectAll")} />,
            render: (r) => <input type="checkbox" checked={selectedIds.has(r.id)} onChange={() => toggleSelect(r.id)} />,
          },
          { key: "name", header: t("masters.spares.name"), render: (r) => <span className="font-medium text-text">{r.name}</span> },
          { key: "sku", header: t("masters.spares.sku"), render: (r) => r.sku || "—" },
          { key: "price", header: t("masters.spares.price"), render: (r) => `₹${r.price}` },
          { key: "cost_price", header: t("masters.spares.costPrice"), render: (r) => (r.cost_price != null ? `₹${r.cost_price}` : t("masters.costPriceNotSet")) },
          { key: "hsn", header: t("masters.spares.hsn"), render: (r) => r.hsn_code || "—" },
          {
            key: "standard_time_minutes",
            header: t("masters.spares.standardTime"),
            render: (r) => (r.standard_time_minutes != null ? t("masters.spares.standardTimeValue", { minutes: r.standard_time_minutes }) : "—"),
          },
          {
            key: "is_active",
            header: t("masters.spares.status"),
            render: (r) => (
              <button
                type="button"
                disabled={updateMut.isPending}
                onClick={() => updateMut.mutate({ id: r.id, patch: { is_active: !r.is_active } })}
                className={`rounded-full px-2 py-0.5 text-xs font-semibold ${
                  r.is_active ? "bg-success/10 text-success" : "bg-danger/10 text-danger"
                }`}
              >
                {r.is_active ? t("masters.active") : t("masters.inactive")}
              </button>
            ),
          },
        ]}
        onCreate={(v) =>
          createMut.mutateAsync({
            org_id: orgId!,
            name: v.name,
            sku: v.sku || null,
            price: Number(v.price) || 0,
            cost_price: v.cost_price ? Number(v.cost_price) : null,
            hsn_code: v.hsn_code || null,
            standard_time_minutes: v.standard_time_minutes ? Number(v.standard_time_minutes) : null,
          })
        }
        onUpdate={(id, v) =>
          updateMut.mutateAsync({
            id,
            patch: {
              name: v.name,
              sku: v.sku || null,
              price: Number(v.price) || 0,
              cost_price: v.cost_price ? Number(v.cost_price) : null,
              hsn_code: v.hsn_code || null,
              standard_time_minutes: v.standard_time_minutes ? Number(v.standard_time_minutes) : null,
            },
          })
        }
        onDelete={(id) => deleteMut.mutateAsync(id)}
      />

      {importOpen ? <SpareBulkImportPanel orgId={orgId} onClose={() => setImportOpen(false)} /> : null}
    </div>
  )
}
