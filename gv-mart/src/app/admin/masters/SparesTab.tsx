import { useMemo, useState } from "react"
import { useTranslation } from "react-i18next"
import { useQueryClient } from "@tanstack/react-query"
import { Loader2, Upload, Video } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { EntityCrudTable, type CrudFieldDef } from "@/components/shared/EntityCrudTable"
import { sparesHooks, useBulkSetSparesActive } from "@/hooks/useMasters"
import { spareHasReferences, type SpareRow } from "@/services/masters"
import { useProfile } from "@/hooks/useProfile"
import { useInventoryList } from "@/hooks/useInventory"
import { setWarehouseStockLimits } from "@/services/inventory"
import { parseStockLimits } from "@/lib/stockLimits"
import { SpareBulkImportPanel } from "./SpareBulkImportPanel"
import { SpareVideosPanel } from "./SpareVideosPanel"

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
  const qc = useQueryClient()
  // spare-stock-limits: min/max warehouse stock (what the auto purchase order uses) edited right here.
  const { data: spareStock } = useInventoryList(orgId, "spare")
  const warehouseBySpare = useMemo(
    () => new Map((spareStock ?? []).filter((r) => r.location === "warehouse").map((r) => [r.item_id, r])),
    [spareStock]
  )
  function checkLimits(v: Record<string, string>) {
    const limits = parseStockLimits(v.min_stock ?? "", v.max_stock ?? "")
    if (limits.kind === "error") throw new Error(t(limits.key))
    return limits
  }
  async function saveLimits(spareId: string, limits: ReturnType<typeof parseStockLimits>) {
    if (limits.kind !== "set") return
    await setWarehouseStockLimits(orgId!, "spare", spareId, limits.min, limits.max)
    qc.invalidateQueries({ queryKey: ["inventory"] })
  }

  // Task 6 (2026-07-30) — search/filter/bulk-select/bulk-import/enable-
  // disable. All client-side over the org's already-fetched spares list
  // (same pattern as the admin Tickets filter bar) — this is a masters
  // list, not paginated data.
  const [search, setSearch] = useState("")
  const [statusFilter, setStatusFilter] = useState<StatusFilter>("all")
  const [selectedIds, setSelectedIds] = useState<Set<string>>(new Set())
  const [importOpen, setImportOpen] = useState(false)
  const [videosSpareId, setVideosSpareId] = useState<string | null>(null)
  const videosSpare = ((rows ?? []) as SpareRow[]).find((r) => r.id === videosSpareId)

  const filteredRows = useMemo(() => {
    const term = search.trim().toLowerCase()
    return ((rows ?? []) as SpareRow[]).filter((r) => {
      if (statusFilter === "active" && !r.is_active) return false
      if (statusFilter === "inactive" && r.is_active) return false
      if (term && !r.name.toLowerCase().includes(term)) return false
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
    // SKU removed from the form on the owner's request (2026-11-27). The column and existing values stay
    // (bulk import + technician spare screens still read them); create/update never send it, so edits keep them.
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
    // spare-stock-limits (2026-11-27): stock at/below min → auto purchase order drafted, refilling up to max.
    { key: "min_stock", label: t("masters.spares.minStock"), type: "number", step: "1", min: 0, placeholder: t("masters.spares.minStockPlaceholder") },
    { key: "max_stock", label: t("masters.spares.maxStock"), type: "number", step: "1", min: 0, placeholder: t("masters.spares.maxStockPlaceholder") },
  ]

  return (
    <div className="space-y-3">
      <div className="flex flex-wrap items-center gap-2">
        <Input value={search} onChange={(e) => setSearch(e.target.value)} placeholder={t("masters.spares.searchPlaceholder")} className="max-w-xs" />
        <select
          aria-label={t("masters.spares.filterStatusLabel")}
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
          price: String(r.price),
          cost_price: r.cost_price != null ? String(r.cost_price) : "",
          hsn_code: r.hsn_code ?? "",
          standard_time_minutes: r.standard_time_minutes != null ? String(r.standard_time_minutes) : "",
          min_stock: warehouseBySpare.get(r.id) ? String(warehouseBySpare.get(r.id)!.min_stock) : "",
          max_stock: warehouseBySpare.get(r.id)?.max_stock != null ? String(warehouseBySpare.get(r.id)!.max_stock) : "",
        })}
        columns={[
          {
            key: "__select",
            header: <input type="checkbox" checked={allFilteredSelected} onChange={toggleSelectAll} aria-label={t("masters.spares.selectAll")} />,
            render: (r) => <input type="checkbox" checked={selectedIds.has(r.id)} onChange={() => toggleSelect(r.id)} />,
          },
          { key: "name", header: t("masters.spares.name"), render: (r) => <span className="font-medium text-text">{r.name}</span> },
          { key: "price", header: t("masters.spares.price"), render: (r) => `₹${r.price}` },
          { key: "cost_price", header: t("masters.spares.costPrice"), render: (r) => (r.cost_price != null ? `₹${r.cost_price}` : t("masters.costPriceNotSet")) },
          { key: "hsn", header: t("masters.spares.hsn"), render: (r) => r.hsn_code || "—" },
          {
            key: "standard_time_minutes",
            header: t("masters.spares.standardTime"),
            render: (r) => (r.standard_time_minutes != null ? t("masters.spares.standardTimeValue", { minutes: r.standard_time_minutes }) : "—"),
          },
          {
            key: "videos",
            header: t("masters.spareVideos.column"),
            render: (r) => (
              <Button size="icon-xs" variant="ghost" title={t("masters.spareVideos.manage")} onClick={() => setVideosSpareId(r.id)}>
                <Video className="size-3.5" />
              </Button>
            ),
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
        onCreate={async (v) => {
          const limits = checkLimits(v) // validated before the spare is created, so a bad pair creates nothing
          const created = await createMut.mutateAsync({
            org_id: orgId!,
            name: v.name,
            price: Number(v.price) || 0,
            cost_price: v.cost_price ? Number(v.cost_price) : null,
            hsn_code: v.hsn_code || null,
            standard_time_minutes: v.standard_time_minutes ? Number(v.standard_time_minutes) : null,
          })
          await saveLimits(created.id, limits)
        }}
        onUpdate={async (id, v) => {
          const limits = checkLimits(v)
          await updateMut.mutateAsync({
            id,
            patch: {
              name: v.name,
              price: Number(v.price) || 0,
              cost_price: v.cost_price ? Number(v.cost_price) : null,
              hsn_code: v.hsn_code || null,
              standard_time_minutes: v.standard_time_minutes ? Number(v.standard_time_minutes) : null,
            },
          })
          await saveLimits(id, limits)
        }}
        onDelete={(id) => deleteMut.mutateAsync(id)}
        checkCanDelete={async (id) => !(await spareHasReferences(id))}
        cannotDeleteMessage={t("masters.cannotDeleteInUse")}
      />

      {importOpen ? <SpareBulkImportPanel orgId={orgId} onClose={() => setImportOpen(false)} /> : null}

      {videosSpare ? (
        <SpareVideosPanel key={videosSpare.id} orgId={orgId} spareId={videosSpare.id} spareName={videosSpare.name} onClose={() => setVideosSpareId(null)} />
      ) : null}
    </div>
  )
}
