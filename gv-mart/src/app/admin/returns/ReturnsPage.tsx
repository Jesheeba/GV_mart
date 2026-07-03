import { useMemo, useState } from "react"
import { useTranslation } from "react-i18next"
import { Loader2, Package, Plus } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Card } from "@/components/ui/card"
import { Label } from "@/components/ui/label"
import { DataTable, type DataTableColumn } from "@/components/shared/DataTable"
import { StatusDot, type StatusTone } from "@/components/shared/StatusDot"
import { useProfile } from "@/hooks/useProfile"
import { useCreateReturn, useInvoicesForPicker, useReturns, useUpdateReturnStatus } from "@/hooks/useSystemPages"
import type { ReturnListItem, ReturnStatus } from "@/services/systemPages"
import type { Enums } from "@/types/database"
import { createReturnSchema } from "@/lib/validation/systemPages"
import { formatCurrency } from "@/lib/sale-calc"

const STATUS_TONE: Record<ReturnStatus, StatusTone> = { requested: "warning", approved: "info", completed: "success", rejected: "danger" }
const NEXT_STATUS: Record<ReturnStatus, ReturnStatus | null> = { requested: "approved", approved: "completed", completed: null, rejected: null }

const textareaClass =
  "w-full min-w-0 rounded-xl border border-input bg-surface px-3.5 py-2.5 text-sm text-text transition-colors outline-none placeholder:text-text-muted focus-visible:border-ring focus-visible:ring-3 focus-visible:ring-ring/30"

export function ReturnsPage() {
  const { t } = useTranslation()
  const { data: profile } = useProfile()
  const { data, isLoading, isError, refetch } = useReturns(profile?.org_id)
  const invoices = useInvoicesForPicker(profile?.org_id)
  const createReturn = useCreateReturn()
  const updateStatus = useUpdateReturnStatus()

  const [formOpen, setFormOpen] = useState(false)
  const [invoiceId, setInvoiceId] = useState("")
  const [itemKey, setItemKey] = useState("")
  const [qty, setQty] = useState("1")
  const [reason, setReason] = useState("")
  const [isReplacement, setIsReplacement] = useState(false)

  const selectedInvoice = invoices.data?.find((i) => i.id === invoiceId)
  const itemOptions = selectedInvoice?.invoice_items ?? []
  const [itemType, itemId] = itemKey.split("::") as [Enums<"item_type"> | undefined, string | undefined]

  const parsed = createReturnSchema.safeParse({
    invoiceId,
    itemType: itemType ?? "",
    itemId: itemId ?? "",
    qty: Number(qty),
    reason,
    isReplacement,
  })

  function resetForm() {
    setInvoiceId("")
    setItemKey("")
    setQty("1")
    setReason("")
    setIsReplacement(false)
    setFormOpen(false)
  }

  function handleCreate() {
    if (!parsed.success || !profile || !itemType || !itemId) return
    createReturn.mutate(
      { orgId: profile.org_id, invoiceId, itemType, itemId, qty: Number(qty), reason: reason.trim() || null, isReplacement },
      { onSuccess: resetForm }
    )
  }

  const columns: DataTableColumn<ReturnListItem>[] = [
    { key: "customer", header: t("returns.table.customer"), render: (r) => r.invoices?.customers?.name ?? "—" },
    { key: "type", header: t("returns.table.itemType"), render: (r) => t(`returns.itemType.${r.item_type}`) },
    { key: "qty", header: t("returns.table.qty"), render: (r) => r.qty },
    { key: "kind", header: t("returns.table.kind"), render: (r) => (r.is_replacement ? t("returns.kind.replacement") : t("returns.kind.return")) },
    { key: "reason", header: t("returns.table.reason"), render: (r) => r.reason ?? "—" },
    { key: "status", header: t("returns.table.status"), render: (r) => <StatusDot tone={STATUS_TONE[r.status as ReturnStatus]} label={t(`returns.status.${r.status}`)} /> },
    {
      key: "actions",
      header: "",
      className: "text-right",
      render: (r) => {
        const next = NEXT_STATUS[r.status as ReturnStatus]
        return (
          <div className="flex items-center justify-end gap-1.5">
            {next ? (
              <Button size="xs" variant="outline" onClick={() => updateStatus.mutate({ id: r.id, status: next })}>
                {t(`returns.actions.moveTo.${next}`)}
              </Button>
            ) : null}
            {r.status === "requested" ? (
              <Button size="xs" variant="ghost" onClick={() => updateStatus.mutate({ id: r.id, status: "rejected" })}>
                {t("returns.actions.reject")}
              </Button>
            ) : null}
          </div>
        )
      },
    },
  ]

  const invoiceOptions = useMemo(
    () => (invoices.data ?? []).map((i) => ({ id: i.id, label: `${(i as { customers?: { name: string } | null }).customers?.name ?? "—"} · ${formatCurrency(i.total)} · ${new Date(i.created_at).toLocaleDateString()}` })),
    [invoices.data]
  )

  return (
    <div className="space-y-4 pt-2">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <div>
          <h1 className="text-2xl font-bold text-text">{t("nav.returns")}</h1>
          <p className="text-sm text-text-muted">{t("returns.subtitle")}</p>
        </div>
        <Button type="button" onClick={() => setFormOpen((v) => !v)}>
          <Plus className="size-3.5" />
          {t("returns.newReturn")}
        </Button>
      </div>

      {formOpen ? (
        <Card size="default" className="gap-3">
          <div className="grid grid-cols-1 gap-3 sm:grid-cols-2">
            <div className="space-y-1 sm:col-span-2">
              <Label htmlFor="r-invoice">{t("returns.form.invoice")}</Label>
              <select
                id="r-invoice"
                value={invoiceId}
                onChange={(e) => {
                  setInvoiceId(e.target.value)
                  setItemKey("")
                }}
                className="h-11 w-full rounded-xl border border-border bg-surface px-3 text-sm text-text outline-none"
              >
                <option value="">{t("returns.form.selectInvoice")}</option>
                {invoiceOptions.map((o) => (
                  <option key={o.id} value={o.id}>
                    {o.label}
                  </option>
                ))}
              </select>
            </div>
            <div className="space-y-1 sm:col-span-2">
              <Label htmlFor="r-item">{t("returns.form.item")}</Label>
              <select
                id="r-item"
                value={itemKey}
                onChange={(e) => setItemKey(e.target.value)}
                disabled={!invoiceId}
                className="h-11 w-full rounded-xl border border-border bg-surface px-3 text-sm text-text outline-none disabled:opacity-50"
              >
                <option value="">{t("returns.form.selectItem")}</option>
                {itemOptions.map((it) => (
                  <option key={it.id} value={`${it.item_type}::${it.item_id}`}>
                    {t(`returns.itemType.${it.item_type}`)} · {t("returns.form.qtyBought", { qty: it.qty })}
                  </option>
                ))}
              </select>
            </div>
            <div className="space-y-1">
              <Label htmlFor="r-qty">{t("returns.form.qty")}</Label>
              <input
                id="r-qty"
                type="number"
                min={1}
                value={qty}
                onChange={(e) => setQty(e.target.value)}
                className="h-11 w-full rounded-xl border border-border bg-surface px-3 text-sm text-text outline-none"
              />
            </div>
            <div className="flex items-center gap-2 pt-6">
              <input id="r-replacement" type="checkbox" checked={isReplacement} onChange={(e) => setIsReplacement(e.target.checked)} className="size-4" />
              <Label htmlFor="r-replacement">{t("returns.form.isReplacement")}</Label>
            </div>
            <div className="space-y-1 sm:col-span-2">
              <Label htmlFor="r-reason">{t("returns.form.reason")}</Label>
              <textarea id="r-reason" rows={2} value={reason} onChange={(e) => setReason(e.target.value)} className={textareaClass} />
            </div>
          </div>
          <div className="flex justify-end gap-2">
            <Button type="button" variant="ghost" size="sm" onClick={resetForm}>
              {t("common.cancel")}
            </Button>
            <Button type="button" size="sm" disabled={!parsed.success || createReturn.isPending} onClick={handleCreate}>
              {createReturn.isPending ? <Loader2 className="size-3.5 animate-spin" /> : t("common.save")}
            </Button>
          </div>
        </Card>
      ) : null}

      {isError ? (
        <Card className="items-center gap-2 py-8 text-center">
          <p className="text-sm text-danger">{t("returns.loadFailed")}</p>
          <Button type="button" variant="outline" size="sm" onClick={() => refetch()}>
            {t("common.retry")}
          </Button>
        </Card>
      ) : !isLoading && (data?.length ?? 0) === 0 ? (
        <Card className="items-center gap-2 py-10 text-center">
          <Package className="size-6 text-text-muted" />
          <p className="text-sm text-text-muted">{t("returns.empty")}</p>
        </Card>
      ) : (
        <DataTable columns={columns} rows={data ?? []} rowKey={(r) => r.id} loading={isLoading} emptyMessage={t("returns.empty")} />
      )}
    </div>
  )
}
