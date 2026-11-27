import { useEffect, useMemo, useRef, useState } from "react"
import { useTranslation } from "react-i18next"
import { GstModeToggle } from "@/components/shared/GstModeToggle"
import { useLocation, useNavigate } from "react-router-dom"
import { Loader2, Search } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Card } from "@/components/ui/card"
import { Label } from "@/components/ui/label"
import { DatePicker } from "@/components/ui/date-picker"
import { Autocomplete } from "@/components/shared/Autocomplete"
import { FullPageLoader } from "@/components/shared/FullPageLoader"
import { useProfile } from "@/hooks/useProfile"
import { useCustomerAutocomplete } from "@/hooks/useCustomers"
import { useLogLeadActivity, useUpdateLeadStatus } from "@/hooks/useAutomation"
import { productsHooks, sparesHooks, useSettings } from "@/hooks/useMasters"
import { useCreateQuotation } from "@/hooks/useQuotations"
import { billBreakdown, defaultGstMode, gstModeParts, type GstMode } from "@/lib/sale-calc"
import type { Enums } from "@/types/database"
import { quotationDiscountProblem } from "@/lib/quotationDiscount"
import { QuotationLinesEditor, type QuoteLine } from "./QuotationLinesEditor"
import { QuotationDiscountField, QuotationTotals, type DiscountState } from "./QuotationDiscountField"

// Set by LeadDetailPanel's "Create Quotation" quick action (navigate(...,
// { state }) — see house style in HistoryPage.tsx/OnSiteVisitPage.tsx).
// `customerId` is only present when the lead is already linked to a
// customer record; leads created from just a name/mobile have it null.
type QuotationNavState = {
  leadId?: string
  customerId?: string | null
  name?: string | null
  mobile?: string | null
  status?: Enums<"lead_status">
  // Spare Enquiry multi-product line items (2026-08-05) — a product/spare
  // enquiry lead carries every structured item it was raised for, so the
  // cart below can seed itself instead of making the admin reselect them.
  items?: { productId?: string | null; spareId?: string | null; qty?: number | null }[]
}

export function QuotationFormPage() {
  const { t } = useTranslation()
  const navigate = useNavigate()
  const location = useLocation()
  const navState = (location.state as QuotationNavState | null) ?? null
  const leadId = navState?.leadId ?? null

  const { data: profile, isLoading: profileLoading } = useProfile()
  const orgId = profile?.org_id

  const [customerId, setCustomerId] = useState<string | null>(navState?.customerId ?? null)
  const [customerLabel, setCustomerLabel] = useState(
    navState?.customerId ? [navState.name, navState.mobile].filter(Boolean).join(" — ") : ""
  )
  const [customerSearch, setCustomerSearch] = useState(!navState?.customerId ? (navState?.name ?? navState?.mobile ?? "") : "")
  const customerResults = useCustomerAutocomplete(orgId, customerSearch)

  const [validUntil, setValidUntil] = useState("")
  const [lines, setLines] = useState<QuoteLine[]>([])

  const { data: products } = productsHooks.useList(orgId)
  const { data: spares } = sparesHooks.useList(orgId)
  const [discount, setDiscount] = useState<DiscountState>({ enabled: false, amount: "", reason: "" })

  const createQuotation = useCreateQuotation()
  const logLeadActivity = useLogLeadActivity()
  const updateLeadStatus = useUpdateLeadStatus()

  const subtotal = useMemo(() => lines.reduce((sum, l) => sum + l.price * l.qty, 0), [lines])
  const { data: settings } = useSettings(orgId)
  const maxDiscountPct = settings ? Number(settings.discount_admin_max) : 10
  const discountAmount = discount.enabled ? Number(discount.amount) || 0 : 0
  const discountProblem = discount.enabled ? quotationDiscountProblem(subtotal, discountAmount, discount.reason, maxDiscountPct) : null
  const gstRate = settings ? Number(settings.gst_rate) : 0
  const [gstModeChoice, setGstModeChoice] = useState<GstMode | null>(null)
  const gstMode = gstModeChoice ?? defaultGstMode(settings?.prices_include_gst)
  const { gstInclusive, noGst, rate: billGstRate } = gstModeParts(gstMode, gstRate)
  const gstBill = billBreakdown(subtotal - discountAmount, 0, billGstRate, gstInclusive)

  // Seed the cart once from the lead's structured items (one entry per
  // product/spare the enquiry asked for), as soon as the products/spares
  // lists are loaded to look them up in. Guarded by a ref (not just
  // navState) so a background refetch of products/spares can't re-append
  // the same lines a second time. Seeded lines are ordinary cart entries —
  // the admin can still remove any of them (removeLine) or add further
  // product/spare lines (addProductLine/addSpareLine) before saving.
  const seededFromLead = useRef(false)
  useEffect(() => {
    if (seededFromLead.current) return
    if (!navState?.items || navState.items.length === 0) return
    if (!products || !spares) return
    seededFromLead.current = true
    const seeded: QuoteLine[] = []
    for (const item of navState.items) {
      if (item.productId) {
        const p = products.find((x) => x.id === item.productId)
        if (p) seeded.push({ itemType: "product", itemId: p.id, name: p.name, price: Number(p.price), qty: Math.max(1, Math.floor(item.qty ?? 1)) })
      }
      if (item.spareId) {
        const s = spares.find((x) => x.id === item.spareId)
        if (s) seeded.push({ itemType: "spare", itemId: s.id, name: s.name, price: Number(s.price), qty: Math.max(1, Math.floor(item.qty ?? 1)) })
      }
    }
    if (seeded.length > 0) setLines((ls) => [...ls, ...seeded])
  }, [products, spares, navState])

  async function handleSubmit() {
    if (!orgId || (!customerId && !leadId) || lines.length === 0 || discountProblem) return
    const id = await createQuotation.mutateAsync({
      orgId,
      customerId,
      leadId,
      validUntil: validUntil || null,
      items: lines.map((l) => ({ itemType: l.itemType, itemId: l.itemId, qty: l.qty })),
      gstInclusive,
      noGst,
      discountAmount,
      discountReason: discountAmount > 0 ? discount.reason.trim() : null,
    })
    if (leadId) {
      // Best-effort: the quotation is already created at this point, so a
      // failure logging/advancing the lead shouldn't block navigation.
      try {
        await logLeadActivity.mutateAsync({ leadId, type: "quotation_created", note: null })
        if (navState?.status === "new" || navState?.status === "contacted") {
          await updateLeadStatus.mutateAsync({ leadId, status: "quoted" })
        }
      } catch {
        // ignore — quotation creation itself already succeeded
      }
    }
    navigate(`/admin/quotations/${id}`)
  }

  if (profileLoading || !orgId) return <FullPageLoader label={t("common.loading")} />

  return (
    <div className="mx-auto max-w-2xl space-y-4 pt-2">
      <h1 className="text-2xl font-bold text-text">{t("quotations.form.title")}</h1>

      <Card className="gap-3 px-5">
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
            setCustomerLabel(c.mobile ? `${c.name} — ${c.mobile}` : c.name)
          }}
        />
        {leadId && !customerId ? <p className="px-1 text-xs text-text-muted">{t("quotations.form.leadNoCustomerHint")}</p> : null}
        <div className="space-y-1.5">
          <Label htmlFor="validUntil">{t("quotations.form.validUntil")}</Label>
          <DatePicker id="validUntil" value={validUntil} onChange={setValidUntil} className="w-48" />
        </div>
      </Card>

      <Card className="gap-3 px-5">
        <p className="px-1 text-sm font-semibold text-text">{t("quotations.form.itemsTitle")}</p>
        <QuotationLinesEditor orgId={orgId} lines={lines} onChange={setLines} />
        {lines.length > 0 ? (
          <>
            <div className="border-t border-border pt-3">
              <QuotationDiscountField value={discount} onChange={setDiscount} subtotal={subtotal} maxPercent={maxDiscountPct} problem={discountProblem} />
            </div>
            <div className="flex flex-wrap items-center justify-between gap-2 border-t border-border px-1 pt-2">
              <GstModeToggle value={gstMode} onChange={setGstModeChoice} />
            </div>
            <QuotationTotals
              subtotal={subtotal}
              discount={discountAmount}
              gstLabel={noGst ? t("sales.gst.notCharged") : t(gstInclusive ? "sales.gst.includedLine" : "sales.summary.gst", { rate: gstRate })}
              gst={gstBill.gst}
              total={gstBill.total}
            />
          </>
        ) : null}
      </Card>

      {createQuotation.isError ? (
        <p className="rounded-xl bg-danger/10 px-3.5 py-2.5 text-sm text-danger">{(createQuotation.error as Error).message}</p>
      ) : null}

      <div className="flex justify-between">
        <Button type="button" variant="outline" onClick={() => navigate(-1)}>
          {t("common.cancel")}
        </Button>
        <Button type="button" disabled={(!customerId && !leadId) || lines.length === 0 || !!discountProblem || createQuotation.isPending} onClick={handleSubmit}>
          {createQuotation.isPending ? <Loader2 className="size-4 animate-spin" /> : t("quotations.form.create")}
        </Button>
      </div>
    </div>
  )
}
