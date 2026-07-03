import { useState } from "react"
import { useTranslation } from "react-i18next"
import { Loader2 } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Card } from "@/components/ui/card"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { DataTable, type DataTableColumn } from "@/components/shared/DataTable"
import { useProfile } from "@/hooks/useProfile"
import { useSuppliersList } from "@/hooks/useSuppliers"
import { useCreateBillEntry, usePurchaseBills, usePurchaseOrders } from "@/hooks/useAutomation"
import { PoItemRows } from "./PoItemRows"
import type { PoItemInput } from "@/lib/validation/automation"
import type { PurchaseBillRow } from "@/services/automation"

export function BillEntryTab() {
  const { t } = useTranslation()
  const { data: profile } = useProfile()
  const orgId = profile?.org_id

  const bills = usePurchaseBills(orgId)
  const { data: suppliers } = useSuppliersList(orgId)
  const { data: pos } = usePurchaseOrders(orgId)
  const createBill = useCreateBillEntry()

  const [supplierId, setSupplierId] = useState("")
  const [poId, setPoId] = useState("")
  const [items, setItems] = useState<PoItemInput[]>([{ itemType: "spare", itemId: "", qty: 1, price: 0 }])
  const [gst, setGst] = useState("0")
  const [billDate, setBillDate] = useState(new Date().toISOString().slice(0, 10))

  async function submit() {
    await createBill.mutateAsync({
      orgId: orgId!,
      supplierId,
      poId: poId || null,
      items: items.filter((i) => i.itemId && i.qty > 0),
      gst: Number(gst) || 0,
      billDate,
      billImageUrl: null,
    })
    setSupplierId("")
    setPoId("")
    setItems([{ itemType: "spare", itemId: "", qty: 1, price: 0 }])
    setGst("0")
  }

  const columns: DataTableColumn<PurchaseBillRow & { suppliers: { name: string } | null }>[] = [
    { key: "supplier", header: t("purchase.po.supplier"), render: (r) => r.suppliers?.name ?? "—" },
    { key: "amount", header: t("purchase.bill.amount"), render: (r) => `₹${r.amount.toLocaleString("en-IN")}` },
    { key: "gst", header: t("purchase.bill.gst"), render: (r) => `₹${r.gst.toLocaleString("en-IN")}` },
    { key: "date", header: t("purchase.bill.date"), render: (r) => new Date(r.created_at).toLocaleDateString("en-IN") },
  ]

  return (
    <div className="space-y-4">
      <Card className="gap-3">
        <h2 className="text-sm font-semibold text-text">{t("purchase.bill.title")}</h2>
        <div className="grid grid-cols-1 gap-3 sm:grid-cols-3">
          <div className="space-y-1.5">
            <Label>{t("purchase.po.supplier")}</Label>
            <select value={supplierId} onChange={(e) => setSupplierId(e.target.value)} className="h-10 w-full rounded-xl border border-border bg-surface px-3 text-sm text-text outline-none">
              <option value="">{t("purchase.items.selectItem")}</option>
              {(suppliers ?? []).map((s) => (
                <option key={s.id} value={s.id}>
                  {s.name}
                </option>
              ))}
            </select>
          </div>
          <div className="space-y-1.5">
            <Label>{t("purchase.bill.linkedPo")}</Label>
            <select value={poId} onChange={(e) => setPoId(e.target.value)} className="h-10 w-full rounded-xl border border-border bg-surface px-3 text-sm text-text outline-none">
              <option value="">{t("purchase.bill.noPo")}</option>
              {(pos ?? []).filter((p) => p.status !== "received" && (!supplierId || p.supplier_id === supplierId)).map((p) => (
                <option key={p.id} value={p.id}>
                  {p.suppliers?.name} · ₹{p.total}
                </option>
              ))}
            </select>
          </div>
          <div className="space-y-1.5">
            <Label>{t("purchase.bill.date")}</Label>
            <Input type="date" value={billDate} onChange={(e) => setBillDate(e.target.value)} />
          </div>
        </div>

        <PoItemRows orgId={orgId} items={items} onChange={setItems} />

        <div className="w-40 space-y-1.5">
          <Label>{t("purchase.bill.gst")}</Label>
          <Input type="number" min={0} step="0.01" value={gst} onChange={(e) => setGst(e.target.value)} />
        </div>

        {createBill.error ? <p className="rounded-xl bg-danger/10 px-3.5 py-2.5 text-sm text-danger">{(createBill.error as Error).message}</p> : null}
        <div className="flex justify-end">
          <Button onClick={submit} disabled={!supplierId || items.every((i) => !i.itemId) || createBill.isPending}>
            {createBill.isPending ? <Loader2 className="size-4 animate-spin" /> : t("common.save")}
          </Button>
        </div>
      </Card>

      <DataTable
        columns={columns}
        rows={bills.data ?? []}
        rowKey={(r) => r.id}
        loading={bills.isLoading}
        error={bills.isError ? t("purchase.loadFailed") : null}
        onRetry={() => bills.refetch()}
        emptyMessage={t("purchase.bill.empty")}
      />
    </div>
  )
}
