import { useState } from "react"
import { getIstNow } from "@/lib/ist"
import { useTranslation } from "react-i18next"
import { zodResolver } from "@hookform/resolvers/zod"
import { Controller, useForm } from "react-hook-form"
import { Loader2, Search } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Card } from "@/components/ui/card"
import { Input } from "@/components/ui/input"
import { ChoiceSelect } from "@/components/shared/ChoiceSelect"
import { GstSummary } from "@/components/shared/GstSummary"
import { focusChoice } from "@/lib/utils"
import { DatePicker } from "@/components/ui/date-picker"
import { Label } from "@/components/ui/label"
import { Autocomplete } from "@/components/shared/Autocomplete"
import { ReferrerField } from "@/components/shared/ReferrerField"
import { EMPTY_REFERRER, type ReferrerValue } from "@/lib/referrer"
import { useProfile } from "@/hooks/useProfile"
import { useCustomerAutocomplete } from "@/hooks/useCustomers"
import { useRoProducts, useSellAmcPlan } from "@/hooks/useAmc"
import { useTechnicians } from "@/hooks/useService"
import { amcPlansHooks, useSettings } from "@/hooks/useMasters"
import { sellAmcSchema, type SellAmcFormInput, type SellAmcInput } from "@/lib/validation/amc"
import type { SellAmcResult } from "@/services/amc"
import { formatCurrency } from "@/lib/sale-calc"
// Fix 1: price_per_year (falling back to price/years for any plan created
// before that column existed) drives the live total below — shared with
// CustomerAmcPage/AmcWarrantyListPage so every screen agrees (see the
// single-source-of-truth note on this function's real definition).
import { amcPlanSummary, pricePerYearOf } from "@/lib/amc-window"
import { productExtraParts } from "@/lib/productSearch"

/** Inline "Sell AMC" panel (ADM-12) — no modal primitive in this codebase
 * yet, so this follows the same inline-expand pattern EntityCrudTable uses
 * for its add/edit form. */
export function SellAmcPanel({ onClose, onSold }: { onClose: () => void; onSold: () => void }) {
  const { t } = useTranslation()
  const { data: profile } = useProfile()
  const orgId = profile?.org_id

  const [customerSearch, setCustomerSearch] = useState("")
  const [customerLabel, setCustomerLabel] = useState("")
  const customerAutocomplete = useCustomerAutocomplete(orgId, customerSearch)
  const { data: roProducts } = useRoProducts(orgId)
  const { data: plans } = amcPlansHooks.useList(orgId)
  const { data: technicians } = useTechnicians(orgId)
  const [referrer, setReferrer] = useState<ReferrerValue>(EMPTY_REFERRER)
  const sellAmc = useSellAmcPlan()
  const { data: orgSettings } = useSettings(orgId)
  // a start date more than this many days in the past needs a master's explicit confirmation (server enforces it too)
  const backdateMaxDays = (orgSettings as { amc_backdate_max_days?: number } | undefined)?.amc_backdate_max_days ?? 7
  const [confirmBackdated, setConfirmBackdated] = useState(false)
  const [sold, setSold] = useState<SellAmcResult | null>(null)
  // null = org default until staff flip the switch (gst-everywhere)
  const [gstChoice, setGstChoice] = useState<boolean | null>(null)
  const gstInclusive = gstChoice ?? !!orgSettings?.prices_include_gst
  const gstRate = Number(orgSettings?.gst_rate ?? 0)

  const form = useForm<SellAmcFormInput, unknown, SellAmcInput>({
    resolver: zodResolver(sellAmcSchema),
    mode: "onChange",
    // Payment method unchosen until staff pick one (choice-no-preselect).
    defaultValues: { customerId: "", productId: "", planId: "", startDate: getIstNow().date, paymentMethod: undefined, txnId: "", paymentDescription: "" },
  })

  const selectedPlan = (plans ?? []).find((p) => p.id === form.watch("planId"))
  const startDate = form.watch("startDate")
  const summary = selectedPlan ? amcPlanSummary(selectedPlan, startDate ?? "") : null
  const computedTotal = selectedPlan ? pricePerYearOf(selectedPlan) * selectedPlan.years : 0
  const daysBack = startDate ? Math.round((Date.parse(getIstNow().date) - Date.parse(startDate)) / 86_400_000) : 0
  const needsBackdateConfirm = daysBack > backdateMaxDays
  const isMaster = profile?.role === "master"
  const paymentMethod = form.watch("paymentMethod")

  async function onSubmit(values: SellAmcInput) {
    const result = await sellAmc.mutateAsync({
      orgId: orgId!,
      customerId: values.customerId,
      productId: values.productId,
      planId: values.planId,
      startDate: values.startDate,
      // no years: the server uses the plan's own duration
      referredByTechnicianId: referrer.kind === "technician" ? referrer.userId || null : null,
      referrer,
      confirmBackdated: needsBackdateConfirm && isMaster && confirmBackdated,
      paymentMethod: values.paymentMethod,
      txnId: values.paymentMethod === "transfer" ? values.txnId : null,
      paymentDescription: values.paymentMethod === "transfer" ? values.paymentDescription : null,
      gstInclusive,
    })
    // visits that were not created are shown, never dropped silently: the user acknowledges them before the panel closes
    if (result.visits_skipped.length > 0) setSold(result)
    else onSold()
  }

  if (sold) {
    return (
      <Card className="gap-3 px-5">
        <h2 className="text-sm font-semibold text-text">{t("amc.sellAmc.skippedTitle")}</h2>
        <p className="text-sm text-text">
          {t("amc.sellAmc.skippedBody", { created: sold.visits_created, expected: sold.visits_expected })}
        </p>
        <ul className="list-disc space-y-0.5 pl-5 text-sm text-text">
          {sold.visits_skipped.map((v) => (
            <li key={v.visit_no}>{t("amc.sellAmc.skippedItem", { no: v.visit_no, date: v.would_have_been_on })}</li>
          ))}
        </ul>
        <p className="text-xs text-text-muted">{t("amc.sellAmc.skippedHint")}</p>
        <div className="flex justify-end">
          <Button onClick={onSold}>{t("amc.sellAmc.skippedAck")}</Button>
        </div>
      </Card>
    )
  }

  return (
    <Card className="gap-3 px-5">
      <div className="flex items-center justify-between">
        <h2 className="text-sm font-semibold text-text">{t("amc.sellAmc.title")}</h2>
        <Button size="sm" variant="ghost" onClick={onClose}>
          {t("common.cancel")}
        </Button>
      </div>

      <div className="space-y-1.5">
        <Label>{t("amc.sellAmc.customer")}</Label>
        <Autocomplete
          value={form.watch("customerId") ? customerLabel : customerSearch}
          onChange={(v) => {
            setCustomerSearch(v)
            form.setValue("customerId", "", { shouldValidate: true })
          }}
          suggestions={customerAutocomplete.data ?? []}
          loading={customerAutocomplete.isFetching}
          icon={<Search className="size-4" />}
          emptyMessage={t("common.noData")}
          getKey={(c) => c.id}
          getLabel={(c) => (
            <span>
              <span className="font-medium">{c.name}</span> <span className="text-text-muted">{c.mobile}</span>
            </span>
          )}
          onSelect={(c) => {
            form.setValue("customerId", c.id, { shouldValidate: true })
            setCustomerLabel(c.mobile ? `${c.name} · ${c.mobile}` : c.name)
          }}
        />
        {form.formState.errors.customerId ? <p className="text-xs text-danger">{t(form.formState.errors.customerId.message!)}</p> : null}
      </div>

      <div className="grid grid-cols-1 gap-3 sm:grid-cols-3">
        <div className="space-y-1.5">
          <Label>{t("amc.sellAmc.roProduct")}</Label>
          <select
            {...form.register("productId")}
            className="h-10 w-full rounded-xl border border-border bg-surface px-3 text-sm text-text outline-none"
          >
            <option value="">{t("common.notSet")}</option>
            {(roProducts ?? []).map((p) => (
              <option key={p.id} value={p.id}>
                {[p.name, ...productExtraParts(p.name, p.brands?.name)].join(" — ")}
              </option>
            ))}
          </select>
          <p className="text-xs text-text-muted">{t("amc.sellAmc.roOnlyHint")}</p>
          {form.formState.errors.productId ? <p className="text-xs text-danger">{t(form.formState.errors.productId.message!)}</p> : null}
        </div>
        <div className="space-y-1.5">
          <Label>{t("amc.sellAmc.plan")}</Label>
          <select
            {...form.register("planId")}
            className="h-10 w-full rounded-xl border border-border bg-surface px-3 text-sm text-text outline-none"
          >
            <option value="">{t("common.notSet")}</option>
            {(plans ?? []).map((p) => (
              <option key={p.id} value={p.id}>
                {p.name} · {p.years}y · ₹{p.price.toLocaleString("en-IN")}
              </option>
            ))}
          </select>
          {form.formState.errors.planId ? <p className="text-xs text-danger">{t(form.formState.errors.planId.message!)}</p> : null}
        </div>
        <div className="space-y-1.5">
          <Label>{t("amc.sellAmc.startDate")}</Label>
          <Controller control={form.control} name="startDate" render={({ field }) => <DatePicker value={field.value ?? ""} onChange={field.onChange} className="w-44" />} />
        </div>
      </div>

      {selectedPlan && summary ? (
        <div className="space-y-0.5 px-1">
          <p className="text-sm text-text">
            {t("amc.sellAmc.planDuration", {
              years: t("amc.sellAmc.yearsCount", { count: summary.years }),
              expiry: summary.expiryLabel ?? "-",
              visits: t("amc.sellAmc.visitsCount", { count: summary.visits }),
            })}
          </p>
          <p className="text-sm text-text">{t("amc.sellAmc.planPrice", { amount: formatCurrency(computedTotal) })}</p>
          <GstSummary net={computedTotal} rate={gstRate} inclusive={gstInclusive} onInclusiveChange={setGstChoice} totalLabel={t("amc.sellAmc.payable")} />
        </div>
      ) : null}

      <div className="space-y-1.5">
        <ChoiceSelect
          id="sell-amc-payment-method"
          label={t("sales.payment.method")}
          value={paymentMethod}
          options={(["cash", "transfer", "upi"] as const).map((m) => ({ value: m, label: t(`sales.payment.${m}`) }))}
          // "" (Not set) is kept as-is so the schema rejects it with the method-required message.
          onChange={(v) => form.setValue("paymentMethod", v as SellAmcFormInput["paymentMethod"], { shouldValidate: true })}
          error={form.formState.errors.paymentMethod ? t(form.formState.errors.paymentMethod.message!) : undefined}
          className="sm:max-w-xs"
        />
        {paymentMethod === "transfer" ? (
          <div className="grid grid-cols-1 gap-3 pt-2 sm:grid-cols-2">
            <div className="space-y-1.5">
              <Label htmlFor="sell-amc-txn">{t("sales.payment.txnId")}</Label>
              <Input id="sell-amc-txn" aria-invalid={!!form.formState.errors.txnId} {...form.register("txnId")} />
              {form.formState.errors.txnId ? <p className="text-xs text-danger">{t(form.formState.errors.txnId.message!)}</p> : null}
            </div>
            <div className="space-y-1.5">
              <Label htmlFor="sell-amc-desc">{t("sales.payment.description")}</Label>
              <Input id="sell-amc-desc" aria-invalid={!!form.formState.errors.paymentDescription} {...form.register("paymentDescription")} />
              {form.formState.errors.paymentDescription ? <p className="text-xs text-danger">{t(form.formState.errors.paymentDescription.message!)}</p> : null}
            </div>
          </div>
        ) : null}
      </div>

      <ReferrerField
        idPrefix="sell-amc-referrer"
        orgId={orgId}
        value={referrer}
        onChange={setReferrer}
        technicians={technicians ?? []}
        excludeCustomerId={form.watch("customerId") || null}
        allowQuickAdd={profile?.role === "master" || profile?.role === "sales_admin"}
      />

      {needsBackdateConfirm ? (
        <div className="space-y-1.5 rounded-xl border border-warning/40 bg-warning/10 px-3.5 py-2.5">
          <p className="text-sm text-text">{t("amc.sellAmc.backdatedWarning", { days: daysBack, limit: backdateMaxDays })}</p>
          {isMaster ? (
            <label className="flex items-center gap-2 text-sm text-text">
              <input type="checkbox" checked={confirmBackdated} onChange={(e) => setConfirmBackdated(e.target.checked)} />
              {t("amc.sellAmc.backdatedConfirm")}
            </label>
          ) : (
            <p className="text-xs text-danger">{t("amc.sellAmc.backdatedMasterOnly")}</p>
          )}
        </div>
      ) : null}

      {sellAmc.error ? <p className="rounded-xl bg-danger/10 px-3.5 py-2.5 text-sm text-danger">{(sellAmc.error as Error).message}</p> : null}

      <div className="flex justify-end">
        <Button
          onClick={form.handleSubmit(onSubmit, (errs) => {
            // The method select is not a registered input, so react-hook-form cannot focus it itself.
            if (errs.paymentMethod && Object.keys(errs).length === 1) focusChoice("sell-amc-payment-method")
          })}
          disabled={sellAmc.isPending || (needsBackdateConfirm && !(isMaster && confirmBackdated))}>
          {sellAmc.isPending ? <Loader2 className="size-4 animate-spin" /> : t("amc.sellAmc.submit")}
        </Button>
      </div>
    </Card>
  )
}
