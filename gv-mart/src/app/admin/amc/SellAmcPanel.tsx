import { useState } from "react"
import { useTranslation } from "react-i18next"
import { zodResolver } from "@hookform/resolvers/zod"
import { useForm } from "react-hook-form"
import { Loader2, Search } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Card } from "@/components/ui/card"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { Autocomplete } from "@/components/shared/Autocomplete"
import { useProfile } from "@/hooks/useProfile"
import { useCustomerAutocomplete } from "@/hooks/useCustomers"
import { useRoProducts, useSellAmcPlan } from "@/hooks/useAmc"
import { amcPlansHooks } from "@/hooks/useMasters"
import { sellAmcSchema, type SellAmcFormInput, type SellAmcInput } from "@/lib/validation/amc"
import { formatCurrency } from "@/lib/sale-calc"
// Fix 1: price_per_year (falling back to price/years for any plan created
// before that column existed) drives the live total below — shared with
// CustomerAmcPage/AmcWarrantyListPage so every screen agrees (see the
// single-source-of-truth note on this function's real definition).
import { pricePerYearOf } from "@/lib/amc-window"

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
  const sellAmc = useSellAmcPlan()

  const form = useForm<SellAmcFormInput, unknown, SellAmcInput>({
    resolver: zodResolver(sellAmcSchema),
    mode: "onChange",
    defaultValues: { customerId: "", productId: "", planId: "", startDate: new Date().toISOString().slice(0, 10), years: 1 },
  })

  const selectedPlan = (plans ?? []).find((p) => p.id === form.watch("planId"))
  const selectedYears = Number(form.watch("years")) || 0
  const computedTotal = selectedPlan ? pricePerYearOf(selectedPlan) * selectedYears : 0

  async function onSubmit(values: SellAmcInput) {
    await sellAmc.mutateAsync({
      orgId: orgId!,
      customerId: values.customerId,
      productId: values.productId,
      planId: values.planId,
      startDate: values.startDate,
      years: values.years,
    })
    onSold()
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
            setCustomerLabel(`${c.name} · ${c.mobile}`)
          }}
        />
        {form.formState.errors.customerId ? <p className="text-xs text-danger">{t(form.formState.errors.customerId.message!)}</p> : null}
      </div>

      <div className="grid grid-cols-1 gap-3 sm:grid-cols-4">
        <div className="space-y-1.5">
          <Label>{t("amc.sellAmc.roProduct")}</Label>
          <select
            {...form.register("productId")}
            className="h-10 w-full rounded-xl border border-border bg-surface px-3 text-sm text-text outline-none"
          >
            <option value="">{t("service.filters.all")}</option>
            {(roProducts ?? []).map((p) => (
              <option key={p.id} value={p.id}>
                {p.name} ({p.brands?.name})
              </option>
            ))}
          </select>
          <p className="text-xs text-text-muted">{t("amc.sellAmc.roOnlyHint")}</p>
          {form.formState.errors.productId ? <p className="text-xs text-danger">{t(form.formState.errors.productId.message!)}</p> : null}
        </div>
        <div className="space-y-1.5">
          <Label>{t("amc.sellAmc.plan")}</Label>
          <select
            {...form.register("planId", {
              onChange: (e) => {
                const plan = (plans ?? []).find((p) => p.id === e.target.value)
                if (plan) form.setValue("years", plan.years, { shouldValidate: true })
              },
            })}
            className="h-10 w-full rounded-xl border border-border bg-surface px-3 text-sm text-text outline-none"
          >
            <option value="">{t("service.filters.all")}</option>
            {(plans ?? []).map((p) => (
              <option key={p.id} value={p.id}>
                {p.name} · {p.years}y · ₹{p.price.toLocaleString("en-IN")}
              </option>
            ))}
          </select>
          {form.formState.errors.planId ? <p className="text-xs text-danger">{t(form.formState.errors.planId.message!)}</p> : null}
        </div>
        <div className="space-y-1.5">
          <Label>{t("amc.sellAmc.years")}</Label>
          <Input type="number" min={1} step="1" {...form.register("years")} />
          {form.formState.errors.years ? <p className="text-xs text-danger">{t(form.formState.errors.years.message!)}</p> : null}
        </div>
        <div className="space-y-1.5">
          <Label>{t("amc.sellAmc.startDate")}</Label>
          <Input type="date" {...form.register("startDate")} />
        </div>
      </div>

      {selectedPlan ? (
        <p className="px-1 text-sm font-medium text-text">{t("amc.sellAmc.totalPrice", { amount: formatCurrency(computedTotal) })}</p>
      ) : null}

      {sellAmc.error ? <p className="rounded-xl bg-danger/10 px-3.5 py-2.5 text-sm text-danger">{(sellAmc.error as Error).message}</p> : null}

      <div className="flex justify-end">
        <Button onClick={form.handleSubmit(onSubmit)} disabled={sellAmc.isPending}>
          {sellAmc.isPending ? <Loader2 className="size-4 animate-spin" /> : t("amc.sellAmc.submit")}
        </Button>
      </div>
    </Card>
  )
}
