import { useEffect, useState } from "react"
import { useTranslation } from "react-i18next"
import { zodResolver } from "@hookform/resolvers/zod"
import { useForm } from "react-hook-form"
import { Loader2, Search } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Card } from "@/components/ui/card"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { DatePicker } from "@/components/ui/date-picker"
import { Autocomplete } from "@/components/shared/Autocomplete"
import { useProfile } from "@/hooks/useProfile"
import { useCustomer, useCustomerAutocomplete } from "@/hooks/useCustomers"
import { productsHooks, rentalPlansHooks } from "@/hooks/useMasters"
import { useCreateRental } from "@/hooks/useRentals"
import { rentOutSchema, type RentOutInput } from "@/lib/validation/rentals"

const PAYMENT_METHODS = ["cash", "transfer", "upi"] as const

function addressLine(a: { door_no: string | null; plot_no: string | null; building_no: string | null; building_name: string | null; flat_no: string | null; street_cross: string | null; area: string | null; pincode: string | null }) {
  return [a.door_no, a.plot_no, a.building_no, a.building_name, a.flat_no, a.street_cross, a.area, a.pincode].filter(Boolean).join(", ")
}

/** Inline "Rent Out" panel (Item D5) — same inline-expand pattern
 * SellAmcPanel.tsx already uses for AMC, on its own dedicated Rentals page
 * rather than folded into the New Sale wizard (rent has no cart, no
 * warranty, no gift threshold — a genuinely different lifecycle). */
export function RentOutPanel({ onClose, onRented }: { onClose: () => void; onRented: () => void }) {
  const { t } = useTranslation()
  const { data: profile } = useProfile()
  const orgId = profile?.org_id

  const [customerSearch, setCustomerSearch] = useState("")
  const [customerLabel, setCustomerLabel] = useState("")
  const customerAutocomplete = useCustomerAutocomplete(orgId, customerSearch)
  const { data: products } = productsHooks.useList(orgId)
  const { data: plans } = rentalPlansHooks.useList(orgId)
  const createRental = useCreateRental()

  const form = useForm<RentOutInput>({
    resolver: zodResolver(rentOutSchema),
    mode: "onChange",
    defaultValues: {
      customerId: "",
      productId: "",
      planId: "",
      addressId: "",
      startDate: new Date().toISOString().slice(0, 10),
      paymentMethod: "cash",
      txnId: "",
      paymentDescription: "",
    },
  })

  const customerId = form.watch("customerId")
  const { data: customer } = useCustomer(customerId || undefined)
  const addresses = customer?.addresses ?? []

  // Reset the address choice whenever the customer changes — an address id
  // from the previous customer would otherwise silently linger selected.
  useEffect(() => {
    form.setValue("addressId", "")
  }, [customerId, form])

  const paymentMethod = form.watch("paymentMethod")
  const selectedPlan = (plans ?? []).find((p) => p.id === form.watch("planId"))

  async function onSubmit(values: RentOutInput) {
    await createRental.mutateAsync({
      orgId: orgId!,
      customerId: values.customerId,
      productId: values.productId,
      planId: values.planId,
      addressId: values.addressId,
      startDate: values.startDate,
      paymentMethod: values.paymentMethod,
      txnId: values.paymentMethod === "transfer" ? values.txnId : null,
      paymentDescription: values.paymentMethod === "transfer" ? values.paymentDescription : null,
    })
    onRented()
  }

  return (
    <Card className="gap-3 px-5">
      <div className="flex items-center justify-between">
        <h2 className="text-sm font-semibold text-text">{t("rentals.rentOut.title")}</h2>
        <Button size="sm" variant="ghost" onClick={onClose}>
          {t("common.cancel")}
        </Button>
      </div>

      <div className="space-y-1.5">
        <Label>{t("rentals.rentOut.customer")}</Label>
        <Autocomplete
          value={customerId ? customerLabel : customerSearch}
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

      {customerId ? (
        <div className="space-y-1.5">
          <Label>{t("rentals.rentOut.address")}</Label>
          <select {...form.register("addressId")} className="h-10 w-full rounded-xl border border-border bg-surface px-3 text-sm text-text outline-none">
            <option value="">{t("service.filters.all")}</option>
            {addresses.map((a) => (
              <option key={a.id} value={a.id}>
                {addressLine(a)}
              </option>
            ))}
          </select>
          {form.formState.errors.addressId ? <p className="text-xs text-danger">{t(form.formState.errors.addressId.message!)}</p> : null}
        </div>
      ) : null}

      <div className="grid grid-cols-1 gap-3 sm:grid-cols-3">
        <div className="space-y-1.5">
          <Label>{t("rentals.rentOut.product")}</Label>
          <select {...form.register("productId")} className="h-10 w-full rounded-xl border border-border bg-surface px-3 text-sm text-text outline-none">
            <option value="">{t("service.filters.all")}</option>
            {(products ?? [])
              .filter((p) => p.is_active)
              .map((p) => (
                <option key={p.id} value={p.id}>
                  {p.name}
                </option>
              ))}
          </select>
          {form.formState.errors.productId ? <p className="text-xs text-danger">{t(form.formState.errors.productId.message!)}</p> : null}
        </div>
        <div className="space-y-1.5">
          <Label>{t("rentals.rentOut.plan")}</Label>
          <select {...form.register("planId")} className="h-10 w-full rounded-xl border border-border bg-surface px-3 text-sm text-text outline-none">
            <option value="">{t("service.filters.all")}</option>
            {(plans ?? []).map((p) => (
              <option key={p.id} value={p.id}>
                {p.name} · ₹{p.monthly_rate}/mo
              </option>
            ))}
          </select>
          {form.formState.errors.planId ? <p className="text-xs text-danger">{t(form.formState.errors.planId.message!)}</p> : null}
        </div>
        <div className="space-y-1.5">
          <Label>{t("rentals.rentOut.startDate")}</Label>
          <DatePicker value={form.watch("startDate")} onChange={(v) => form.setValue("startDate", v, { shouldValidate: true })} />
        </div>
      </div>

      {selectedPlan ? (
        <p className="px-1 text-sm font-medium text-text">
          {t("rentals.rentOut.monthlyTotal", { amount: `₹${selectedPlan.monthly_rate}` })}
        </p>
      ) : null}

      <div className="space-y-1.5">
        <Label>{t("sales.payment.method")}</Label>
        <div className="flex gap-2">
          {PAYMENT_METHODS.map((m) => (
            <button
              key={m}
              type="button"
              onClick={() => form.setValue("paymentMethod", m, { shouldValidate: true })}
              className={`rounded-full px-4 py-1.5 text-sm font-medium transition-colors ${
                paymentMethod === m ? "bg-ink text-white" : "bg-surface-alt text-text-muted"
              }`}
            >
              {t(`sales.payment.${m}`)}
            </button>
          ))}
        </div>
        {paymentMethod === "transfer" ? (
          <div className="grid grid-cols-1 gap-3 pt-2 sm:grid-cols-2">
            <div className="space-y-1.5">
              <Label htmlFor="txnId">{t("sales.payment.txnId")}</Label>
              <Input id="txnId" {...form.register("txnId")} />
            </div>
            <div className="space-y-1.5">
              <Label htmlFor="paymentDescription">{t("sales.payment.description")}</Label>
              <Input id="paymentDescription" {...form.register("paymentDescription")} />
            </div>
          </div>
        ) : null}
      </div>

      {createRental.error ? <p className="rounded-xl bg-danger/10 px-3.5 py-2.5 text-sm text-danger">{(createRental.error as Error).message}</p> : null}

      <div className="flex justify-end">
        <Button onClick={form.handleSubmit(onSubmit)} disabled={createRental.isPending}>
          {createRental.isPending ? <Loader2 className="size-4 animate-spin" /> : t("rentals.rentOut.submit")}
        </Button>
      </div>
    </Card>
  )
}
