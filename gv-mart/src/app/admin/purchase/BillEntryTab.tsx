import { useEffect, useRef, useState } from "react"
import { getIstNow } from "@/lib/ist"
import { useTranslation } from "react-i18next"
import { FileText, Loader2, RotateCcw } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Card } from "@/components/ui/card"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { DatePicker } from "@/components/ui/date-picker"
import { DataTable, type DataTableColumn } from "@/components/shared/DataTable"
import { useProfile } from "@/hooks/useProfile"
import { useSuppliersList } from "@/hooks/useSuppliers"
import { useCreateBillEntry, useLastBillEntry, usePoItems, usePurchaseBills, usePurchaseOrders } from "@/hooks/useAutomation"
import { PoItemRows } from "./PoItemRows"
import { billEntrySchema, type PoItemInput } from "@/lib/validation/automation"
import { receivablePurchaseOrders } from "@/lib/purchase"
import { purchaseBillPhotoSignedUrl, uploadPurchaseBillPhoto } from "@/services/automation"
import { expenseCategories } from "@/lib/validation/reports"
import type { PurchaseBillRow } from "@/services/automation"
import type { Enums } from "@/types/database"
import { formatDate } from "@/lib/formatDate"

export function BillEntryTab() {
  const { t } = useTranslation()
  const { data: profile } = useProfile()
  const orgId = profile?.org_id

  const bills = usePurchaseBills(orgId)
  const { data: suppliers } = useSuppliersList(orgId)
  const { data: pos } = usePurchaseOrders(orgId)
  const createBill = useCreateBillEntry()
  const lastBill = useLastBillEntry(orgId)

  const [supplierId, setSupplierId] = useState("")
  const [poId, setPoId] = useState("")
  const [items, setItems] = useState<PoItemInput[]>([{ itemType: "spare", itemId: "", qty: 1, price: 0 }])
  const [gst, setGst] = useState("0")
  const [billDate, setBillDate] = useState(getIstNow().date)
  // Build Order Step 1.3: was hardcoded to 'purchase' server-side regardless
  // of what was actually bought — defaults to 'purchase' (the common case
  // for a supplier bill) but staff can now pick any real category so the
  // P&L breakdown reflects it, same enum/i18n as the manual Log Expense panel.
  const [category, setCategory] = useState<Enums<"expense_category">>("purchase")
  const [isPrefilled, setIsPrefilled] = useState(false)
  const [photo, setPhoto] = useState<File | null>(null)
  const [photoInputKey, setPhotoInputKey] = useState(0)
  const [formError, setFormError] = useState<string | null>(null)
  const [uploading, setUploading] = useState(false)
  const activeSuppliers = (suppliers ?? []).filter((s) => s.is_active || s.id === supplierId)
  const receivablePos = receivablePurchaseOrders(pos ?? [], supplierId)

  // Picking a PO fills supplier + lines from that PO, so the bill matches what was ordered;
  // staff then adjust quantities to what actually arrived. Gift lines can't be edited here.
  const selectedPoItems = usePoItems(poId || undefined)
  const poHasGiftLines = (selectedPoItems.data ?? []).some((i) => i.item_type === "gift")
  const appliedPoRef = useRef<string | null>(null)
  useEffect(() => {
    if (!poId || !selectedPoItems.data || appliedPoRef.current === poId) return
    appliedPoRef.current = poId
    const po = (pos ?? []).find((p) => p.id === poId)
    if (po) setSupplierId(po.supplier_id)
    const lines = selectedPoItems.data
      .filter((i): i is typeof i & { item_type: "product" | "spare" } => i.item_type === "product" || i.item_type === "spare")
      .map((i) => ({ itemType: i.item_type, itemId: i.item_id, qty: i.qty, price: Number(i.price) }))
    if (lines.length > 0) setItems(lines)
    setIsPrefilled(false)
  }, [poId, selectedPoItems.data, pos])

  // Prefill once, from the org's last bill, the first time this form is
  // opened — not after every submit (a submit already clears the form back
  // to blank below, since a bill was just filed).
  const appliedPrefillRef = useRef(false)
  useEffect(() => {
    if (appliedPrefillRef.current || !lastBill.data) return
    appliedPrefillRef.current = true
    setSupplierId(lastBill.data.supplierId)
    if (lastBill.data.items.length > 0) setItems(lastBill.data.items)
    setIsPrefilled(true)
  }, [lastBill.data])

  function clearPrefill() {
    setSupplierId("")
    setPoId("")
    setItems([{ itemType: "spare", itemId: "", qty: 1, price: 0 }])
    setIsPrefilled(false)
  }

  async function submit() {
    const parsed = billEntrySchema.safeParse({ supplierId, poId, items: items.filter((i) => i.itemId), gst: gst === "" ? 0 : gst, billDate })
    if (!parsed.success) {
      setFormError(t(parsed.error.issues[0].message))
      return
    }
    setFormError(null)
    let billImageUrl: string | null = null
    if (photo) {
      setUploading(true)
      try {
        billImageUrl = await uploadPurchaseBillPhoto(orgId!, photo)
      } catch (e) {
        const msg = (e as Error).message
        setFormError(msg.startsWith("purchase.") ? t(msg) : msg)
        return
      } finally {
        setUploading(false)
      }
    }
    await createBill.mutateAsync({
      orgId: orgId!,
      supplierId,
      poId: poId || null,
      items: parsed.data.items,
      gst: parsed.data.gst,
      billDate,
      billImageUrl,
      category,
    })
    setPhoto(null)
    setPhotoInputKey((k) => k + 1)
    appliedPoRef.current = null
    setSupplierId("")
    setPoId("")
    setItems([{ itemType: "spare", itemId: "", qty: 1, price: 0 }])
    setGst("0")
    setCategory("purchase")
    setIsPrefilled(false)
  }

  async function openBillPhoto(path: string) {
    // open the tab first (synchronously) so popup blockers allow it, then point it at the signed URL
    const tab = window.open("", "_blank")
    if (tab) tab.opener = null
    try {
      const url = await purchaseBillPhotoSignedUrl(path)
      if (tab) tab.location.href = url
    } catch (e) {
      tab?.close()
      setFormError((e as Error).message)
    }
  }

  const columns: DataTableColumn<PurchaseBillRow & { suppliers: { name: string } | null }>[] = [
    { key: "supplier", header: t("purchase.po.supplier"), render: (r) => r.suppliers?.name ?? "—" },
    { key: "amount", header: t("purchase.bill.amount"), render: (r) => `₹${r.amount.toLocaleString("en-IN")}` },
    { key: "gst", header: t("purchase.bill.gst"), render: (r) => `₹${r.gst.toLocaleString("en-IN")}` },
    { key: "date", header: t("purchase.bill.date"), render: (r) => formatDate(r.bill_date) },
    {
      key: "photo",
      header: "",
      className: "text-right",
      render: (r) =>
        r.bill_image_url ? (
          <Button size="sm" variant="ghost" onClick={() => openBillPhoto(r.bill_image_url!)}>
            <FileText className="size-3.5" />
            {t("purchase.bill.viewPhoto")}
          </Button>
        ) : null,
    },
  ]

  return (
    <div className="space-y-4">
      <Card className="gap-3 px-5">
        <h2 className="text-sm font-semibold text-text">{t("purchase.bill.title")}</h2>

        {isPrefilled ? (
          <div className="flex items-center justify-between gap-3 rounded-xl bg-primary/10 px-3.5 py-2.5 text-sm text-text">
            <span>{t("purchase.bill.prefillNotice")}</span>
            <Button size="sm" variant="ghost" onClick={clearPrefill}>
              <RotateCcw className="size-3.5" />
              {t("purchase.bill.clearPrefill")}
            </Button>
          </div>
        ) : null}

        <div className="grid grid-cols-1 gap-3 sm:grid-cols-3">
          <div className="space-y-1.5">
            <Label>{t("purchase.po.supplier")}</Label>
            <select
              value={supplierId}
              onChange={(e) => {
                setSupplierId(e.target.value)
                setPoId("")
                appliedPoRef.current = null
              }} className="h-10 w-full rounded-xl border border-border bg-surface px-3 text-sm text-text outline-none">
              <option value="">{t("purchase.items.selectItem")}</option>
              {activeSuppliers.map((s) => (
                <option key={s.id} value={s.id}>
                  {s.name}
                </option>
              ))}
            </select>
          </div>
          <div className="space-y-1.5">
            <Label>{t("purchase.bill.linkedPo")}</Label>
            <select
              value={poId}
              onChange={(e) => {
                setPoId(e.target.value)
                appliedPoRef.current = null
              }} className="h-10 w-full rounded-xl border border-border bg-surface px-3 text-sm text-text outline-none">
              <option value="">{t("purchase.bill.noPo")}</option>
              {receivablePos.map((p) => (
                <option key={p.id} value={p.id}>
                  {p.suppliers?.name} · ₹{p.total}
                </option>
              ))}
            </select>
          </div>
          <div className="space-y-1.5">
            <Label>{t("purchase.bill.date")}</Label>
            <DatePicker value={billDate} onChange={setBillDate} />
          </div>
        </div>

        <PoItemRows orgId={orgId} items={items} onChange={setItems} />

        <div className="flex flex-wrap gap-3">
          <div className="w-40 space-y-1.5">
            <Label>{t("purchase.bill.gst")}</Label>
            <Input type="number" min={0} step="0.01" value={gst} onChange={(e) => setGst(e.target.value)} />
          </div>
          <div className="w-48 space-y-1.5">
            <Label>{t("reports.pnl.category")}</Label>
            <select
              value={category}
              onChange={(e) => setCategory(e.target.value as Enums<"expense_category">)}
              className="h-10 w-full rounded-xl border border-border bg-surface px-3 text-sm text-text outline-none"
            >
              {expenseCategories.map((c) => (
                <option key={c} value={c}>
                  {t(`reports.pnl.expenseCategory.${c}`)}
                </option>
              ))}
            </select>
          </div>
        </div>

        <div className="space-y-1.5">
          <Label htmlFor="bill-photo">{t("purchase.bill.photo")}</Label>
          <Input
            id="bill-photo"
            key={photoInputKey}
            type="file"
            accept="image/jpeg,image/png,image/webp,application/pdf"
            onChange={(e) => setPhoto(e.target.files?.[0] ?? null)}
          />
        </div>

        {poId ? <p className="text-xs text-text-muted">{t("purchase.bill.prefilledFromPo")}</p> : null}
        {poHasGiftLines ? <p className="rounded-xl bg-warning/10 px-3.5 py-2.5 text-sm text-warning">{t("purchase.bill.poHasGifts")}</p> : null}
        {formError ? <p className="rounded-xl bg-danger/10 px-3.5 py-2.5 text-sm text-danger">{formError}</p> : null}
        {createBill.error ? <p className="rounded-xl bg-danger/10 px-3.5 py-2.5 text-sm text-danger">{(createBill.error as Error).message}</p> : null}
        <div className="flex justify-end">
          <Button onClick={submit} disabled={!supplierId || items.every((i) => !i.itemId) || poHasGiftLines || createBill.isPending || uploading}>
            {createBill.isPending || uploading ? <Loader2 className="size-4 animate-spin" /> : t("common.save")}
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
