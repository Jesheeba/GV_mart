import { useMemo, useState } from "react"
import { useTranslation } from "react-i18next"
import { Loader2, Plus, Star, Trash2 } from "lucide-react"
import { Card } from "@/components/ui/card"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { DataTable, type DataTableColumn } from "@/components/shared/DataTable"
import { useProfile } from "@/hooks/useProfile"
import {
  useCatalogForLinking,
  useLinkSupplierItem,
  useSupplierProducts,
  useUnlinkSupplierItem,
  useUpdateSupplierItem,
} from "@/hooks/useSuppliers"
import type { ItemType, SupplierRow } from "@/services/suppliers"

type LinkedRow = { id: string; item_type: ItemType; item_id: string; itemName: string; price: number; lead_time_days: number | null; is_preferred: boolean }

export function SupplierItemsPanel({ supplier }: { supplier: SupplierRow }) {
  const { t } = useTranslation()
  const { data: profile } = useProfile()
  const orgId = profile?.org_id

  const { data: links, isLoading, isError, refetch } = useSupplierProducts(orgId, supplier.id)
  const { data: catalog } = useCatalogForLinking(orgId)
  const linkMut = useLinkSupplierItem(orgId, supplier.id)
  const updateMut = useUpdateSupplierItem(orgId, supplier.id)
  const unlinkMut = useUnlinkSupplierItem(orgId, supplier.id)

  const [showForm, setShowForm] = useState(false)
  const [itemType, setItemType] = useState<ItemType>("product")
  const [itemId, setItemId] = useState("")
  const [price, setPrice] = useState("")
  const [leadTime, setLeadTime] = useState("")
  const [confirmingId, setConfirmingId] = useState<string | null>(null)

  const catalogOptions = useMemo(
    () => (itemType === "product" ? catalog?.products ?? [] : catalog?.spares ?? []),
    [catalog, itemType]
  )

  function submitLink() {
    if (!itemId || !price) return
    linkMut.mutate(
      { item_type: itemType, item_id: itemId, price: Number(price) || 0, lead_time_days: leadTime ? Number(leadTime) : null, is_preferred: false },
      { onSuccess: () => { setShowForm(false); setItemId(""); setPrice(""); setLeadTime("") } }
    )
  }

  const columns: DataTableColumn<LinkedRow>[] = [
    { key: "item", header: t("suppliers.item"), render: (r) => <span className="font-medium text-text">{r.itemName}</span> },
    { key: "price", header: t("suppliers.price"), render: (r) => `₹${r.price}` },
    { key: "leadTime", header: t("suppliers.leadTime"), render: (r) => (r.lead_time_days != null ? t("suppliers.days", { count: r.lead_time_days }) : "—") },
    {
      key: "preferred",
      header: t("suppliers.preferred"),
      render: (r) => (
        <button
          type="button"
          onClick={() => updateMut.mutate({ id: r.id, patch: { is_preferred: !r.is_preferred } })}
          className={`flex items-center gap-1 text-xs font-medium ${r.is_preferred ? "text-accent" : "text-text-muted"}`}
        >
          <Star className={r.is_preferred ? "size-3.5 fill-current" : "size-3.5"} />
          {r.is_preferred ? t("suppliers.preferredYes") : t("suppliers.markPreferred")}
        </button>
      ),
    },
    {
      key: "actions",
      header: "",
      className: "text-right",
      render: (r) =>
        confirmingId === r.id ? (
          <span className="flex items-center justify-end gap-1.5 text-xs">
            <button type="button" className="text-danger hover:underline" onClick={() => { unlinkMut.mutate(r.id); setConfirmingId(null) }}>
              {t("masters.confirmDelete")}
            </button>
            <button type="button" className="text-text-muted hover:underline" onClick={() => setConfirmingId(null)}>
              {t("common.cancel")}
            </button>
          </span>
        ) : (
          <div className="flex justify-end">
            <Button size="icon-xs" variant="ghost" onClick={() => setConfirmingId(r.id)}>
              <Trash2 className="size-3.5 text-danger" />
            </Button>
          </div>
        ),
    },
  ]

  return (
    <Card className="gap-3 px-5">
      <div className="flex items-center justify-between px-1">
        <h3 className="text-sm font-semibold text-text">{t("suppliers.itemsFor", { name: supplier.name })}</h3>
        <Button size="sm" variant={showForm ? "outline" : "accent"} onClick={() => setShowForm((v) => !v)}>
          <Plus className="size-3.5" />
          {t("suppliers.linkItem")}
        </Button>
      </div>

      {showForm ? (
        <div className="grid grid-cols-2 gap-3 rounded-xl border border-border p-3.5 sm:grid-cols-4">
          <div className="space-y-1">
            <Label>{t("suppliers.itemType")}</Label>
            <div className="flex gap-1 rounded-full bg-surface-alt p-1">
              {(["product", "spare"] as const).map((v) => (
                <button
                  key={v}
                  type="button"
                  onClick={() => { setItemType(v); setItemId("") }}
                  className={`flex-1 rounded-full px-2 py-1.5 text-xs font-medium ${itemType === v ? "bg-ink text-white" : "text-text-muted"}`}
                >
                  {t(`masters.tabs.${v}s`)}
                </button>
              ))}
            </div>
          </div>
          <div className="space-y-1">
            <Label>{t("suppliers.item")}</Label>
            <select
              value={itemId}
              onChange={(e) => setItemId(e.target.value)}
              className="h-10 w-full rounded-xl border border-border bg-surface px-3 text-sm text-text outline-none"
            >
              <option value="">{t("suppliers.selectItem")}</option>
              {catalogOptions.map((o) => (
                <option key={o.id} value={o.id}>
                  {o.name}
                </option>
              ))}
            </select>
          </div>
          <div className="space-y-1">
            <Label>{t("suppliers.price")}</Label>
            <Input type="number" step="0.01" value={price} onChange={(e) => setPrice(e.target.value)} />
          </div>
          <div className="space-y-1">
            <Label>{t("suppliers.leadTime")}</Label>
            <Input type="number" step="1" value={leadTime} onChange={(e) => setLeadTime(e.target.value)} />
          </div>
          <div className="col-span-full flex justify-end gap-2">
            <Button size="sm" variant="ghost" onClick={() => setShowForm(false)}>
              {t("common.cancel")}
            </Button>
            <Button size="sm" onClick={submitLink} disabled={linkMut.isPending || !itemId || !price}>
              {linkMut.isPending ? <Loader2 className="size-3.5 animate-spin" /> : t("common.save")}
            </Button>
          </div>
        </div>
      ) : null}

      <DataTable
        columns={columns}
        rows={(links ?? []) as LinkedRow[]}
        rowKey={(r) => r.id}
        loading={isLoading}
        error={isError ? t("suppliers.loadFailed") : null}
        onRetry={() => refetch()}
        emptyMessage={t("suppliers.noItemsLinked")}
      />
    </Card>
  )
}
