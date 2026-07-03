import { useMemo, useState } from "react"
import { useTranslation } from "react-i18next"
import { useNavigate } from "react-router-dom"
import { Loader2, Plus, Search, Trash2 } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Card } from "@/components/ui/card"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { Autocomplete } from "@/components/shared/Autocomplete"
import { FullPageLoader } from "@/components/shared/FullPageLoader"
import { useProfile } from "@/hooks/useProfile"
import { useCustomerAutocomplete } from "@/hooks/useCustomers"
import { productsHooks, sparesHooks } from "@/hooks/useMasters"
import { useCreateQuotation } from "@/hooks/useQuotations"
import { formatCurrency } from "@/lib/sale-calc"
import type { Enums } from "@/types/database"

const selectClass = "h-10 w-full rounded-xl border border-border bg-surface px-3.5 text-sm text-text outline-none"

type QuoteLine = { itemType: Enums<"item_type">; itemId: string; name: string; price: number; qty: number }

export function QuotationFormPage() {
  const { t } = useTranslation()
  const navigate = useNavigate()
  const { data: profile, isLoading: profileLoading } = useProfile()
  const orgId = profile?.org_id

  const [customerId, setCustomerId] = useState<string | null>(null)
  const [customerLabel, setCustomerLabel] = useState("")
  const [customerSearch, setCustomerSearch] = useState("")
  const customerResults = useCustomerAutocomplete(orgId, customerSearch)

  const [validUntil, setValidUntil] = useState("")
  const [lines, setLines] = useState<QuoteLine[]>([])

  const { data: products } = productsHooks.useList(orgId)
  const { data: spares } = sparesHooks.useList(orgId)
  const [productId, setProductId] = useState("")
  const [spareId, setSpareId] = useState("")
  const [qty, setQty] = useState("1")

  const createQuotation = useCreateQuotation()

  const total = useMemo(() => lines.reduce((sum, l) => sum + l.price * l.qty, 0), [lines])

  function addProductLine() {
    const p = (products ?? []).find((x) => x.id === productId)
    if (!p) return
    setLines((ls) => [...ls, { itemType: "product", itemId: p.id, name: p.name, price: Number(p.price), qty: Math.max(1, Number(qty) || 1) }])
    setProductId("")
    setQty("1")
  }
  function addSpareLine() {
    const s = (spares ?? []).find((x) => x.id === spareId)
    if (!s) return
    setLines((ls) => [...ls, { itemType: "spare", itemId: s.id, name: s.name, price: Number(s.price), qty: Math.max(1, Number(qty) || 1) }])
    setSpareId("")
    setQty("1")
  }
  function removeLine(i: number) {
    setLines((ls) => ls.filter((_, idx) => idx !== i))
  }

  async function handleSubmit() {
    if (!orgId || !customerId || lines.length === 0) return
    const id = await createQuotation.mutateAsync({
      orgId,
      customerId,
      validUntil: validUntil || null,
      items: lines.map((l) => ({ itemType: l.itemType, itemId: l.itemId, qty: l.qty })),
    })
    navigate(`/admin/quotations/${id}`)
  }

  if (profileLoading || !orgId) return <FullPageLoader label={t("common.loading")} />

  return (
    <div className="mx-auto max-w-2xl space-y-4 pt-2">
      <h1 className="text-2xl font-bold text-text">{t("quotations.form.title")}</h1>

      <Card className="gap-3">
        <Label htmlFor="quote-customer">{t("sales.customer.searchLabel")}</Label>
        <Autocomplete
          id="quote-customer"
          value={customerId ? customerLabel : customerSearch}
          onChange={(v) => {
            setCustomerSearch(v)
            setCustomerId(null)
          }}
          suggestions={customerResults.data ?? []}
          loading={customerResults.isFetching}
          icon={<Search className="size-4" />}
          placeholder={t("sales.customer.searchPlaceholder")}
          emptyMessage={t("common.noData")}
          getKey={(c) => c.id}
          getLabel={(c) => (
            <span>
              <span className="font-medium">{c.name}</span> <span className="text-text-muted">{c.mobile}</span>
            </span>
          )}
          onSelect={(c) => {
            setCustomerId(c.id)
            setCustomerLabel(`${c.name} — ${c.mobile}`)
          }}
        />
        <div className="space-y-1.5">
          <Label htmlFor="validUntil">{t("quotations.form.validUntil")}</Label>
          <Input id="validUntil" type="date" value={validUntil} onChange={(e) => setValidUntil(e.target.value)} className="w-48" />
        </div>
      </Card>

      <Card className="gap-3">
        <p className="px-1 text-sm font-semibold text-text">{t("quotations.form.itemsTitle")}</p>
        <div className="grid grid-cols-2 gap-2 px-1 sm:grid-cols-4">
          <select className={selectClass} value={productId} onChange={(e) => setProductId(e.target.value)}>
            <option value="">{t("sales.items.selectProduct")}</option>
            {(products ?? []).map((p) => (
              <option key={p.id} value={p.id}>
                {p.name} — {formatCurrency(Number(p.price))}
              </option>
            ))}
          </select>
          <Input type="number" min={1} value={qty} onChange={(e) => setQty(e.target.value)} placeholder={t("sales.items.qty")} />
          <Button type="button" size="sm" variant="outline" disabled={!productId} onClick={addProductLine}>
            <Plus className="size-3.5" />
            {t("sales.items.add")}
          </Button>
        </div>
        <div className="grid grid-cols-2 gap-2 px-1 sm:grid-cols-4">
          <select className={selectClass} value={spareId} onChange={(e) => setSpareId(e.target.value)}>
            <option value="">{t("sales.items.selectSpare")}</option>
            {(spares ?? []).map((s) => (
              <option key={s.id} value={s.id}>
                {s.name} — {formatCurrency(Number(s.price))}
              </option>
            ))}
          </select>
          <Input type="number" min={1} value={qty} onChange={(e) => setQty(e.target.value)} placeholder={t("sales.items.qty")} />
          <Button type="button" size="sm" variant="outline" disabled={!spareId} onClick={addSpareLine}>
            <Plus className="size-3.5" />
            {t("sales.items.add")}
          </Button>
        </div>

        {lines.length === 0 ? (
          <p className="px-1 text-sm text-text-muted">{t("sales.items.emptyCart")}</p>
        ) : (
          <div className="space-y-2 px-1">
            {lines.map((l, i) => (
              <div key={`${l.itemId}-${i}`} className="flex items-center justify-between rounded-xl border border-border px-3.5 py-2.5">
                <div>
                  <p className="text-sm font-medium text-text">{l.name}</p>
                  <p className="text-xs text-text-muted">
                    {l.qty} × {formatCurrency(l.price)} = {formatCurrency(l.qty * l.price)}
                  </p>
                </div>
                <Button type="button" size="icon-xs" variant="ghost" onClick={() => removeLine(i)}>
                  <Trash2 className="size-3.5 text-danger" />
                </Button>
              </div>
            ))}
            <div className="flex justify-between border-t border-border px-1 pt-2 text-sm font-bold text-text">
              <span>{t("sales.summary.total")}</span>
              <span>{formatCurrency(total)}</span>
            </div>
          </div>
        )}
      </Card>

      {createQuotation.isError ? (
        <p className="rounded-xl bg-danger/10 px-3.5 py-2.5 text-sm text-danger">{(createQuotation.error as Error).message}</p>
      ) : null}

      <div className="flex justify-between">
        <Button type="button" variant="outline" onClick={() => navigate(-1)}>
          {t("common.cancel")}
        </Button>
        <Button type="button" disabled={!customerId || lines.length === 0 || createQuotation.isPending} onClick={handleSubmit}>
          {createQuotation.isPending ? <Loader2 className="size-4 animate-spin" /> : t("quotations.form.create")}
        </Button>
      </div>
    </div>
  )
}
