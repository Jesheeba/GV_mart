import { useEffect, useRef, useState } from "react"
import { useTranslation } from "react-i18next"
import { useNavigate, useSearchParams } from "react-router-dom"
import { Loader2, Search } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Card } from "@/components/ui/card"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { Stepper } from "@/components/shared/Stepper"
import { Autocomplete } from "@/components/shared/Autocomplete"
import { FullPageLoader } from "@/components/shared/FullPageLoader"
import { DraftBanner } from "@/components/shared/DraftBanner"
import { useProfile } from "@/hooks/useProfile"
import { useCustomer, useCustomerAutocomplete } from "@/hooks/useCustomers"
import { useSettings, giftsHooks, brandsHooks, modelsHooks, productsHooks, sparesHooks } from "@/hooks/useMasters"
import { useInventoryList } from "@/hooks/useInventory"
import { useCreateSale, useCustomerReferralBalance } from "@/hooks/useSales"
import { useQuotation } from "@/hooks/useQuotations"
import { useTechnicians } from "@/hooks/useService"
import { useLocalDraft } from "@/hooks/useLocalDraft"
import { discountNeedsApproval, isAmountPaidBlocked, isDiscountBlocked, paymentDetailsSchema } from "@/lib/validation/sale"
import { formatCurrency } from "@/lib/sale-calc"
import { ItemsStep } from "./ItemsStep"
import { SaleSummaryPanel } from "./SaleSummaryPanel"
import { cartIsEmpty, combinedSubtotal, payableTotal, type CartProductLine, type CartSpareLine, type SaleCartState } from "./types"
import type { Enums } from "@/types/database"

const STEP_KEYS = ["customer", "items", "discount", "gift", "payment", "review"] as const
const DRAFT_KEY = "gv_mart_draft:admin_new_sale"

/** Restorable subset of the wizard's state — see useLocalDraft. Skipped
 * entirely (key is null) for the "convert this quotation" entry point,
 * where resurrecting an unrelated older draft over the fresh quotation
 * prefill would silently discard/overwrite that prefill instead of helping. */
type NewSaleDraftData = {
  step: number
  customerId: string | null
  customerLabel: string
  customerSearch: string
  cart: SaleCartState
  discountInput: string
  giftId: string | null
  paymentMethod: Enums<"payment_method">
  txnId: string
  paymentDescription: string
  redeemPointsInput: string
  amountPaidInput: string
  amountPaidTouched: boolean
}

/**
 * ADM-05 (New Sale) and ADM-06 (Product Sale sub-flow) are one stepper, not
 * two screens: choosing "Product" in the Items step is what surfaces the
 * per-line Warranty/Installation toggles ADM-06 describes — see ItemsStep.
 * The cart itself is a genuine mix of product + spare lines (not an
 * exclusive type choice), which is what makes the "two separate bills"
 * rule in create_sale meaningful.
 */
export function NewSalePage() {
  const { t } = useTranslation()
  const navigate = useNavigate()
  const [searchParams] = useSearchParams()
  const quotationId = searchParams.get("fromQuotation")

  const { data: profile, isLoading: profileLoading } = useProfile()
  const orgId = profile?.org_id

  const [step, setStep] = useState(0)
  // Only ever grows — tracks the furthest step reached so navigating back
  // (which decreases `step`) doesn't make already-completed steps lose their
  // checkmark in the Stepper below. See Stepper's `maxCompletedIndex` doc.
  const [maxStepReached, setMaxStepReached] = useState(0)
  const [customerId, setCustomerId] = useState<string | null>(null)
  const [customerLabel, setCustomerLabel] = useState("")
  const [customerSearch, setCustomerSearch] = useState("")
  const customerResults = useCustomerAutocomplete(orgId, customerSearch)

  const [cart, setCart] = useState<SaleCartState>({ productLines: [], spareLines: [], amc: null })
  const [discountInput, setDiscountInput] = useState("0")
  const discountPercent = Math.max(0, Number(discountInput) || 0)
  const [giftId, setGiftId] = useState<string | null>(null)
  const [paymentMethod, setPaymentMethod] = useState<Enums<"payment_method">>("cash")
  const [txnId, setTxnId] = useState("")
  const [paymentDescription, setPaymentDescription] = useState("")
  const [paymentError, setPaymentError] = useState<string | null>(null)
  const [redeemPointsInput, setRedeemPointsInput] = useState("0")
  // Amount actually collected — defaults to (and keeps tracking) the live
  // payable total until the cashier types over it, so a normal
  // fully-paid-now sale needs zero extra input; only a genuine partial/due
  // sale requires typing a smaller number.
  const [amountPaidInput, setAmountPaidInput] = useState("")
  const [amountPaidTouched, setAmountPaidTouched] = useState(false)
  const [referredByTechnicianId, setReferredByTechnicianId] = useState("")

  const { data: settings } = useSettings(orgId)
  const { data: technicians } = useTechnicians(orgId)
  const { data: gifts } = giftsHooks.useList(orgId)
  // Stock is informational here, not a hard gate — an out-of-stock gift is
  // still selectable (it just won't physically decrement below 0; see
  // gift_logs_decrement_stock trigger). A gift is a bonus, never a blocker
  // to a paying customer, so this only helps the cashier pick an in-stock
  // gift when more than one qualifies.
  const { data: giftInventory } = useInventoryList(orgId, "gift")
  const { data: referralBalance } = useCustomerReferralBalance(customerId ?? undefined)
  const createSale = useCreateSale()

  // Referral point redemption (v2.2 §6.8): points are worth an admin-set ₹
  // amount (settings.referral_point_value). The raw input can exceed the
  // balance while typing — redeemPoints (what's actually sent to
  // create_sale) is always clamped to the customer's current balance; the
  // server re-derives and re-validates that same balance independently, so
  // this clamp is a UX nicety, not the real guard.
  const referralPointValue = settings ? Number(settings.referral_point_value) : 50
  const referralBalanceNum = referralBalance ?? 0
  const redeemPointsRaw = Math.max(0, Math.floor(Number(redeemPointsInput) || 0))
  const redeemPoints = Math.min(redeemPointsRaw, referralBalanceNum)
  const redeemAmount = redeemPoints * referralPointValue

  // Convert-a-quotation: prefill the cart once from the quotation's items,
  // and preselect its customer — the sale itself is still built through the
  // normal stepper (discount/gift/payment aren't carried over, matching
  // "New Quotation = sale flow minus payment").
  const quotationData = useQuotation(orgId, quotationId ?? undefined)
  const { data: allBrands } = brandsHooks.useList(orgId)
  const { data: allModels } = modelsHooks.useList(orgId)
  const { data: allProducts } = productsHooks.useList(orgId)
  const { data: allSpares } = sparesHooks.useList(orgId)
  const quotationCustomer = useCustomer(quotationData.data?.customer_id ?? undefined)
  // A ref, not state: state set inside an effect isn't guaranteed visible to
  // a StrictMode-driven second invocation of the same effect (dev-only
  // double-invoke), which duplicated every prefilled line the first time
  // this used useState — a ref mutates synchronously so the guard holds.
  const prefilledRef = useRef(false)

  useEffect(() => {
    if (prefilledRef.current || !quotationData.data || !allProducts || !allSpares) return
    prefilledRef.current = true
    const productLines: CartProductLine[] = []
    const spareLines: CartSpareLine[] = []
    for (const item of quotationData.data.quotation_items) {
      if (item.item_type === "product") {
        const p = allProducts.find((x) => x.id === item.item_id)
        if (!p) continue
        const brand = allBrands?.find((b) => b.id === p.brand_id)
        const model = allModels?.find((m) => m.id === p.model_id)
        productLines.push({
          productId: p.id,
          name: p.name,
          brandName: brand?.name ?? "—",
          modelName: model?.name ?? "—",
          category: p.category,
          price: Number(p.price),
          qty: item.qty,
          warranty: false,
          warrantyMonths: p.warranty_months,
          installation: false,
        })
      } else {
        const s = allSpares.find((x) => x.id === item.item_id)
        if (!s) continue
        spareLines.push({ spareId: s.id, name: s.name, price: Number(s.price), qty: item.qty })
      }
    }
    setCart((c) => ({ ...c, productLines: [...c.productLines, ...productLines], spareLines: [...c.spareLines, ...spareLines] }))
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [quotationData.data, allProducts, allSpares, allBrands, allModels])

  useEffect(() => {
    if (quotationCustomer.data && !customerId) {
      setCustomerId(quotationCustomer.data.id)
      setCustomerLabel(`${quotationCustomer.data.name} — ${quotationCustomer.data.mobile}`)
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [quotationCustomer.data])

  // Local draft persistence — see useLocalDraft's doc comment. Disabled for
  // the fromQuotation entry point (see NewSaleDraftData).
  const draftKey = quotationId ? null : DRAFT_KEY
  const draftSnapshot: NewSaleDraftData = {
    step,
    customerId,
    customerLabel,
    customerSearch,
    cart,
    discountInput,
    giftId,
    paymentMethod,
    txnId,
    paymentDescription,
    redeemPointsInput,
    amountPaidInput,
    amountPaidTouched,
  }
  const { restoredDraft, wasRestored, discardDraft, clearDraft } = useLocalDraft<NewSaleDraftData>(draftKey, draftSnapshot)
  const appliedDraftRef = useRef(false)
  useEffect(() => {
    if (appliedDraftRef.current || !restoredDraft) return
    appliedDraftRef.current = true
    if (restoredDraft.step != null) {
      setStep(restoredDraft.step)
      setMaxStepReached((m) => Math.max(m, restoredDraft.step))
    }
    if (restoredDraft.customerId) setCustomerId(restoredDraft.customerId)
    if (restoredDraft.customerLabel) setCustomerLabel(restoredDraft.customerLabel)
    if (restoredDraft.customerSearch) setCustomerSearch(restoredDraft.customerSearch)
    if (restoredDraft.cart) setCart(restoredDraft.cart)
    if (restoredDraft.discountInput != null) setDiscountInput(restoredDraft.discountInput)
    if (restoredDraft.giftId !== undefined) setGiftId(restoredDraft.giftId)
    if (restoredDraft.paymentMethod) setPaymentMethod(restoredDraft.paymentMethod)
    if (restoredDraft.txnId) setTxnId(restoredDraft.txnId)
    if (restoredDraft.paymentDescription) setPaymentDescription(restoredDraft.paymentDescription)
    if (restoredDraft.redeemPointsInput != null) setRedeemPointsInput(restoredDraft.redeemPointsInput)
    if (restoredDraft.amountPaidInput != null) setAmountPaidInput(restoredDraft.amountPaidInput)
    if (restoredDraft.amountPaidTouched != null) setAmountPaidTouched(restoredDraft.amountPaidTouched)
  }, [restoredDraft])

  const techMax = settings ? Number(settings.discount_tech_max) : 5
  const adminMax = settings ? Number(settings.discount_admin_max) : 10
  const combined = combinedSubtotal(cart)
  const eligibleGifts = (gifts ?? []).filter((g) => combined >= Number(g.threshold_amount))
  const selectedGift = (gifts ?? []).find((g) => g.id === giftId) ?? null
  const giftStockById = new Map((giftInventory ?? []).map((r) => [r.item_id, r.stock_qty]))

  const gstRate = settings ? Number(settings.gst_rate) : 0
  const computedPayable = payableTotal(cart, discountPercent, gstRate, redeemAmount)
  useEffect(() => {
    if (!amountPaidTouched) setAmountPaidInput(computedPayable.toFixed(2))
  }, [computedPayable, amountPaidTouched])
  const amountPaid = Math.max(0, Number(amountPaidInput) || 0)
  const amountDue = Math.max(0, computedPayable - amountPaid)

  const steps = STEP_KEYS.map((key) => ({ key, label: t(`sales.steps.${key}`) }))

  function canAdvanceFrom(index: number) {
    if (index === 0) return !!customerId
    if (index === 1) return !cartIsEmpty(cart)
    if (index === 2) return !isDiscountBlocked(discountPercent, adminMax)
    return true
  }

  function handlePaymentContinue() {
    const result = paymentDetailsSchema.safeParse({ method: paymentMethod, txnId, description: paymentDescription, amountPaid })
    if (!result.success) {
      setPaymentError(result.error.issues[0]?.message ?? "sales.errors.paymentInvalid")
      return
    }
    if (isAmountPaidBlocked(amountPaid, computedPayable)) {
      setPaymentError("sales.errors.amountPaidExceedsTotal")
      return
    }
    setPaymentError(null)
    setStep(5)
    setMaxStepReached((m) => Math.max(m, 5))
  }

  async function handleGenerate() {
    if (!orgId || !customerId) return
    const result = await createSale.mutateAsync({
      orgId,
      customerId,
      cart: {
        spareItems: cart.spareLines.map((l) => ({ itemId: l.spareId, qty: l.qty })),
        productItems: cart.productLines.map((l) => ({
          itemId: l.productId,
          qty: l.qty,
          warranty: l.warranty,
          warrantyMonths: l.warrantyMonths,
          installation: l.installation,
        })),
        amc: cart.amc ? { productId: cart.amc.productId, planId: cart.amc.planId } : null,
        discountPercent,
        giftId,
        paymentMethod,
        txnId: paymentMethod === "transfer" ? txnId : null,
        paymentDescription: paymentMethod === "transfer" ? paymentDescription : null,
        redeemPoints,
      },
      quotationId,
      referredByTechnicianId: referredByTechnicianId || null,
      amountPaid,
    })
    clearDraft()
    const primaryInvoiceId = result.product_invoice_id ?? result.spare_invoice_id ?? result.amc_invoice_id
    if (primaryInvoiceId) navigate(`/admin/sales/invoices/${primaryInvoiceId}`)
    else navigate("/admin/sales")
  }

  if (profileLoading || !orgId) return <FullPageLoader label={t("common.loading")} />

  return (
    <div className="mx-auto max-w-5xl space-y-4 pt-2">
      <h1 className="text-2xl font-bold text-text">{t("sales.newSale.title")}</h1>
      {draftKey ? (
        <DraftBanner
          restored={wasRestored}
          autosaveNote={t("sales.newSale.draft.autosaveNote")}
          restoredNote={t("sales.newSale.draft.restoredNote")}
          discardLabel={t("sales.newSale.draft.discard")}
          discardWarning={t("sales.newSale.draft.discardWarning")}
          confirmDiscardLabel={t("sales.newSale.draft.confirmDiscard")}
          cancelLabel={t("common.cancel")}
          onConfirmDiscard={() => {
            discardDraft()
            setStep(0)
            setMaxStepReached(0)
            setCustomerId(null)
            setCustomerLabel("")
            setCustomerSearch("")
            setCart({ productLines: [], spareLines: [], amc: null })
            setDiscountInput("0")
            setGiftId(null)
            setPaymentMethod("cash")
            setTxnId("")
            setPaymentDescription("")
            setRedeemPointsInput("0")
            setAmountPaidInput("")
            setAmountPaidTouched(false)
            setReferredByTechnicianId("")
          }}
        />
      ) : null}
      <Card className="px-5">
        <Stepper steps={steps} currentIndex={step} maxCompletedIndex={maxStepReached} />
      </Card>

      <div className="grid gap-4 lg:grid-cols-[1fr_320px]">
        <div className="space-y-4">
          {step === 0 ? (
            <Card className="gap-3 px-5">
              <Label htmlFor="customer-search">{t("sales.customer.searchLabel")}</Label>
              <Autocomplete
                id="customer-search"
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
              <p className="px-1 text-xs text-text-muted">
                {t("sales.customer.notFound")}{" "}
                <a className="text-accent underline" href="/admin/customers/new" target="_blank" rel="noreferrer">
                  {t("sales.customer.addNew")}
                </a>
              </p>
            </Card>
          ) : null}

          {step === 1 ? <ItemsStep orgId={orgId} cart={cart} setCart={setCart} /> : null}

          {step === 2 ? (
            <Card className="gap-3 px-5">
              <Label htmlFor="discount">{t("sales.discount.label")}</Label>
              <Input
                id="discount"
                type="number"
                min={0}
                max={adminMax}
                step="0.5"
                value={discountInput}
                onChange={(e) => setDiscountInput(e.target.value)}
                className="w-32"
              />
              <p className="text-xs text-text-muted">{t("sales.discount.freeUpTo", { max: techMax })}</p>
              <p className="text-xs text-warning">{t("sales.discount.approvalBand", { min: techMax, max: adminMax })}</p>
              <p className="text-xs text-danger">{t("sales.discount.blockedAbove", { max: adminMax })}</p>
              {isDiscountBlocked(discountPercent, adminMax) ? (
                <p className="rounded-xl bg-danger/10 px-3.5 py-2.5 text-sm text-danger">{t("sales.discount.blockedMessage", { max: adminMax })}</p>
              ) : discountNeedsApproval(discountPercent, techMax, adminMax) ? (
                <p className="rounded-xl bg-warning/10 px-3.5 py-2.5 text-sm text-warning">{t("sales.discount.needsApprovalMessage")}</p>
              ) : null}

              {referralBalanceNum > 0 ? (
                <div className="space-y-1.5 border-t border-border pt-3">
                  <Label htmlFor="redeemPoints">{t("sales.redeem.label")}</Label>
                  <p className="text-xs text-text-muted">{t("sales.redeem.balance", { count: referralBalanceNum })}</p>
                  <Input
                    id="redeemPoints"
                    type="number"
                    min={0}
                    max={referralBalanceNum}
                    step="1"
                    value={redeemPointsInput}
                    onChange={(e) => setRedeemPointsInput(e.target.value)}
                    className="w-32"
                  />
                  <p className="text-xs text-text-muted">{t("sales.redeem.hint", { value: formatCurrency(referralPointValue) })}</p>
                  {redeemPointsRaw > referralBalanceNum ? (
                    <p className="text-xs text-danger">{t("sales.redeem.exceedsBalance")}</p>
                  ) : redeemPoints > 0 ? (
                    <p className="text-xs text-success">{t("sales.redeem.discountPreview", { amount: formatCurrency(redeemAmount) })}</p>
                  ) : null}
                </div>
              ) : null}
            </Card>
          ) : null}

          {step === 3 ? (
            <Card className="gap-3 px-5">
              <p className="text-sm font-semibold text-text">{t("sales.gift.title")}</p>
              {eligibleGifts.length === 0 ? (
                <p className="text-sm text-text-muted">{t("sales.gift.noneEligible")}</p>
              ) : (
                <div className="space-y-2">
                  <button
                    type="button"
                    onClick={() => setGiftId(null)}
                    className={`block w-full rounded-xl border px-3.5 py-2.5 text-left text-sm ${!giftId ? "border-accent bg-accent-soft text-accent" : "border-border text-text"}`}
                  >
                    {t("sales.gift.none")}
                  </button>
                  {eligibleGifts.map((g) => {
                    const stock = giftStockById.get(g.id)
                    const outOfStock = stock !== undefined && stock <= 0
                    return (
                      <button
                        key={g.id}
                        type="button"
                        onClick={() => setGiftId(g.id)}
                        className={`flex w-full items-center justify-between gap-2 rounded-xl border px-3.5 py-2.5 text-left text-sm ${giftId === g.id ? "border-accent bg-accent-soft text-accent" : "border-border text-text"}`}
                      >
                        <span>
                          {g.name} — {t("sales.gift.thresholdNote", { amount: formatCurrency(Number(g.threshold_amount)) })}
                        </span>
                        {outOfStock ? (
                          <span className="shrink-0 rounded-full bg-danger/10 px-2 py-0.5 text-[11px] font-bold text-danger">
                            {t("inventory.status.out")}
                          </span>
                        ) : null}
                      </button>
                    )
                  })}
                </div>
              )}
            </Card>
          ) : null}

          {step === 4 ? (
            <Card className="gap-3 px-5">
              <Label>{t("sales.payment.method")}</Label>
              <div className="flex w-fit gap-1 rounded-full bg-surface-alt p-1">
                {(["cash", "transfer"] as const).map((m) => (
                  <button
                    key={m}
                    type="button"
                    onClick={() => setPaymentMethod(m)}
                    className={`rounded-full px-4 py-1.5 text-sm font-medium transition-colors ${paymentMethod === m ? "bg-ink text-white" : "text-text-muted"}`}
                  >
                    {t(`sales.payment.${m}`)}
                  </button>
                ))}
              </div>
              {paymentMethod === "transfer" ? (
                <div className="grid grid-cols-1 gap-3 sm:grid-cols-2">
                  <div className="space-y-1.5">
                    <Label htmlFor="txnId">{t("sales.payment.txnId")}</Label>
                    <Input id="txnId" value={txnId} onChange={(e) => setTxnId(e.target.value)} />
                  </div>
                  <div className="space-y-1.5">
                    <Label htmlFor="paymentDescription">{t("sales.payment.description")}</Label>
                    <Input id="paymentDescription" value={paymentDescription} onChange={(e) => setPaymentDescription(e.target.value)} />
                  </div>
                </div>
              ) : null}
              <p className="text-xs text-text-muted">{t("sales.payment.noGatewayNote")}</p>

              <div className="space-y-1.5 border-t border-border pt-3">
                <Label htmlFor="amountPaid">{t("sales.payment.amountCollected")}</Label>
                <Input
                  id="amountPaid"
                  type="number"
                  min={0}
                  step="0.01"
                  value={amountPaidInput}
                  onChange={(e) => {
                    setAmountPaidTouched(true)
                    setAmountPaidInput(e.target.value)
                  }}
                  className="w-40"
                />
                <p className="text-xs text-text-muted">{t("sales.payment.payableNote", { amount: formatCurrency(computedPayable) })}</p>
                {amountDue > 0.01 ? (
                  <p className="rounded-xl bg-warning/10 px-3.5 py-2.5 text-sm text-warning">
                    {amountPaid <= 0
                      ? t("sales.payment.willBeDue")
                      : t("sales.payment.willBePartial", { amount: formatCurrency(amountDue) })}
                  </p>
                ) : null}
              </div>

              {paymentError ? <p className="text-xs text-danger">{t(paymentError)}</p> : null}
            </Card>
          ) : null}

          {step === 5 ? (
            <Card className="gap-3 px-5">
              <p className="text-sm font-semibold text-text">{t("sales.review.title")}</p>
              <p className="text-sm text-text">{t("sales.review.customer", { customer: customerLabel })}</p>
              <p className="text-sm text-text">{t("sales.review.discount", { percent: discountPercent })}</p>
              <p className="text-sm text-text">{t("sales.review.payment", { method: t(`sales.payment.${paymentMethod}`) })}</p>
              {selectedGift ? <p className="text-sm text-success">{t("sales.summary.giftApplied", { gift: selectedGift.name })}</p> : null}
              {redeemPoints > 0 ? (
                <p className="text-sm text-success">{t("sales.review.redeemPoints", { points: redeemPoints, amount: formatCurrency(redeemAmount) })}</p>
              ) : null}

              <div className="space-y-1.5 border-t border-border pt-3">
                <Label>{t("common.referredByTechnician")}</Label>
                <select
                  value={referredByTechnicianId}
                  onChange={(e) => setReferredByTechnicianId(e.target.value)}
                  className="h-10 w-full rounded-xl border border-border bg-surface px-3 text-sm text-text outline-none sm:max-w-xs"
                >
                  <option value="">{t("common.none")}</option>
                  {(technicians ?? []).map((tech) => (
                    <option key={tech.id} value={tech.id}>
                      {tech.full_name}
                    </option>
                  ))}
                </select>
              </div>

              {createSale.isError ? (
                <p className="rounded-xl bg-danger/10 px-3.5 py-2.5 text-sm text-danger">{(createSale.error as Error).message}</p>
              ) : null}
            </Card>
          ) : null}
        </div>

        <SaleSummaryPanel orgId={orgId} cart={cart} discountPercent={discountPercent} giftName={selectedGift?.name} redeemAmount={redeemAmount} />
      </div>

      <div className="flex justify-between">
        <Button type="button" variant="outline" onClick={() => (step === 0 ? navigate(-1) : setStep(step - 1))}>
          {step === 0 ? t("common.cancel") : t("sales.newSale.back")}
        </Button>
        {step < 4 ? (
          <Button
            type="button"
            disabled={!canAdvanceFrom(step)}
            onClick={() => {
              const next = step + 1
              setStep(next)
              setMaxStepReached((m) => Math.max(m, next))
            }}
          >
            {t("sales.newSale.next")}
          </Button>
        ) : step === 4 ? (
          <Button type="button" onClick={handlePaymentContinue}>
            {t("sales.newSale.next")}
          </Button>
        ) : (
          <Button type="button" onClick={handleGenerate} disabled={createSale.isPending}>
            {createSale.isPending ? <Loader2 className="size-4 animate-spin" /> : t("sales.newSale.generate")}
          </Button>
        )}
      </div>
    </div>
  )
}
