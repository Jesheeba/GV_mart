import { useEffect } from "react"
import { useTranslation } from "react-i18next"
import { useForm } from "react-hook-form"
import { zodResolver } from "@hookform/resolvers/zod"
import { Loader2 } from "lucide-react"
import { Card } from "@/components/ui/card"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { Button } from "@/components/ui/button"
import { FullPageLoader } from "@/components/shared/FullPageLoader"
import { useProfile } from "@/hooks/useProfile"
import { usePaymentSettings, useUpdatePaymentSettings } from "@/hooks/usePaymentSettings"
import { paymentSettingsSchema, type PaymentSettingsInput } from "@/lib/validation/paymentSettings"
import { PaymentQRCode } from "@/app/customer/components/PaymentQRCode"

const PREVIEW_AMOUNT = 100

export function PaymentSettingsTab() {
  const { t } = useTranslation()
  const { data: profile } = useProfile()
  const orgId = profile?.org_id
  const { data: settings, isLoading } = usePaymentSettings(orgId)
  const updateMut = useUpdatePaymentSettings(orgId)

  const {
    register,
    handleSubmit,
    reset,
    watch,
    formState: { errors, isDirty },
  } = useForm<PaymentSettingsInput>({ resolver: zodResolver(paymentSettingsSchema), mode: "onChange" })

  useEffect(() => {
    reset({
      merchant_name: settings?.merchant_name ?? "",
      upi_id: settings?.upi_id ?? "",
      phone_number: settings?.phone_number ?? "",
      payment_enabled: settings?.payment_enabled ?? false,
    })
  }, [settings, reset])

  if (isLoading) return <FullPageLoader label={t("common.loading")} />

  const onSubmit = handleSubmit((values) =>
    updateMut.mutate({
      merchant_name: values.merchant_name,
      upi_id: values.upi_id,
      phone_number: values.phone_number || null,
      payment_enabled: values.payment_enabled,
    })
  )

  const watchedMerchantName = watch("merchant_name")
  const watchedUpiId = watch("upi_id")
  const upiIdValid = paymentSettingsSchema.shape.upi_id.safeParse(watchedUpiId).success

  return (
    <form onSubmit={onSubmit} className="space-y-4">
      <Card className="gap-4">
        <div>
          <h3 className="px-1 text-sm font-semibold text-text">{t("paymentSettings.title")}</h3>
          <p className="px-1 text-xs text-text-muted">{t("paymentSettings.hint")}</p>
        </div>
        <div className="grid grid-cols-1 gap-3 px-1 sm:grid-cols-2">
          <div className="space-y-1">
            <Label htmlFor="merchant_name">{t("paymentSettings.merchantName")}</Label>
            <Input id="merchant_name" aria-invalid={!!errors.merchant_name} {...register("merchant_name")} />
            {errors.merchant_name ? <p className="text-xs text-danger">{t(errors.merchant_name.message!)}</p> : null}
          </div>
          <div className="space-y-1">
            <Label htmlFor="upi_id">{t("paymentSettings.upiId")}</Label>
            <Input id="upi_id" placeholder={t("paymentSettings.upiIdPlaceholder")} aria-invalid={!!errors.upi_id} {...register("upi_id")} />
            {errors.upi_id ? <p className="text-xs text-danger">{t(errors.upi_id.message!)}</p> : null}
          </div>
          <div className="space-y-1">
            <Label htmlFor="phone_number">{t("paymentSettings.phoneNumber")}</Label>
            <Input id="phone_number" {...register("phone_number")} />
          </div>
        </div>
        <label className="mx-1 flex items-center gap-2.5 rounded-xl border border-border bg-surface-alt px-3.5 py-2.5 text-sm text-text">
          <input type="checkbox" className="size-4 accent-accent" {...register("payment_enabled")} />
          <span>
            <span className="block font-medium">{t("paymentSettings.enabled")}</span>
            <span className="block text-xs text-text-muted">{t("paymentSettings.enabledHint")}</span>
          </span>
        </label>

        {upiIdValid && watchedMerchantName ? (
          <div className="mx-1 rounded-xl border border-border bg-surface-alt/40 p-4">
            <p className="mb-3 text-xs font-medium text-text-muted">{t("paymentSettings.previewLabel")}</p>
            <PaymentQRCode upiId={watchedUpiId} merchantName={watchedMerchantName} amount={PREVIEW_AMOUNT} invoiceNumber="PREVIEW" />
          </div>
        ) : null}

        {updateMut.isError ? (
          <p className="mx-1 rounded-xl bg-danger/10 px-3.5 py-2.5 text-sm text-danger">{(updateMut.error as Error).message}</p>
        ) : null}
        {updateMut.isSuccess ? <p className="mx-1 rounded-xl bg-success/10 px-3.5 py-2.5 text-sm text-success">{t("paymentSettings.saved")}</p> : null}

        <div className="flex justify-end">
          <Button type="submit" disabled={!isDirty || updateMut.isPending}>
            {updateMut.isPending ? <Loader2 className="size-4 animate-spin" /> : t("common.save")}
          </Button>
        </div>
      </Card>
    </form>
  )
}
