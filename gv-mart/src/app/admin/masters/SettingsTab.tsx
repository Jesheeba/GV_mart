import { useEffect } from "react"
import { useTranslation } from "react-i18next"
import { useForm } from "react-hook-form"
import { zodResolver } from "@hookform/resolvers/zod"
import { Loader2 } from "lucide-react"
import { Card } from "@/components/ui/card"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { Button } from "@/components/ui/button"
import { FullPageError, FullPageLoader } from "@/components/shared/FullPageLoader"
import { useSettings, useUpdateSettings } from "@/hooks/useMasters"
import { useProfile } from "@/hooks/useProfile"
import { settingsSchema, type SettingsFormInput, type SettingsOutput } from "@/lib/validation/settings"

function hhmm(value: string) {
  return value.slice(0, 5)
}

export function SettingsTab() {
  const { t } = useTranslation()
  const { data: profile } = useProfile()
  const orgId = profile?.org_id
  const { data: settings, isLoading, isError, refetch } = useSettings(orgId)
  const updateMut = useUpdateSettings(orgId)

  const {
    register,
    handleSubmit,
    reset,
    formState: { errors, isDirty },
  } = useForm<SettingsFormInput, unknown, SettingsOutput>({ resolver: zodResolver(settingsSchema), mode: "onChange" })

  useEffect(() => {
    if (settings) {
      reset({
        per_km_minutes: Number(settings.per_km_minutes),
        geofence_radius_m: settings.geofence_radius_m,
        work_start: hhmm(settings.work_start),
        work_end: hhmm(settings.work_end),
        late_cutoff: hhmm(settings.late_cutoff),
        lunch_minutes_allowed: settings.lunch_minutes_allowed,
        lunch_minutes_red_threshold: settings.lunch_minutes_red_threshold,
        discount_tech_max: Number(settings.discount_tech_max),
        discount_admin_max: Number(settings.discount_admin_max),
        amc_book_window_days: settings.amc_book_window_days,
        referral_point_value: Number(settings.referral_point_value),
        review_link_min_stars: Number(settings.review_link_min_stars),
        default_min_stock: settings.default_min_stock,
        default_reorder_qty: settings.default_reorder_qty,
        gst_rate: Number(settings.gst_rate),
        sla_hours_very_urgent: Number(settings.sla_hours_very_urgent),
        sla_hours_urgent: Number(settings.sla_hours_urgent),
        sla_hours_normal: Number(settings.sla_hours_normal),
      })
    }
  }, [settings, reset])

  if (isLoading) return <FullPageLoader label={t("common.loading")} />
  if (isError || !settings) {
    return <FullPageError message={t("masters.loadFailed")} onRetry={() => refetch()} retryLabel={t("common.retry")} />
  }

  const onSubmit = handleSubmit((values) => updateMut.mutate(values))

  const field = (key: keyof SettingsFormInput, label: string, type: "number" | "time", step?: string) => (
    <div className="space-y-1">
      <Label htmlFor={key}>{label}</Label>
      <Input id={key} type={type} step={step} aria-invalid={!!errors[key]} {...register(key)} />
      {errors[key] ? <p className="text-xs text-danger">{t(errors[key]!.message!)}</p> : null}
    </div>
  )

  return (
    <form onSubmit={onSubmit} className="space-y-4">
      <Card className="gap-4">
        <h3 className="px-1 text-sm font-semibold text-text">{t("settings.groups.travel")}</h3>
        <div className="grid grid-cols-2 gap-3 px-1 sm:grid-cols-3">
          {field("per_km_minutes", t("settings.perKmMinutes"), "number", "0.5")}
          {field("geofence_radius_m", t("settings.geofenceRadius"), "number", "1")}
        </div>
      </Card>

      <Card className="gap-4">
        <h3 className="px-1 text-sm font-semibold text-text">{t("settings.groups.attendance")}</h3>
        <div className="grid grid-cols-2 gap-3 px-1 sm:grid-cols-3">
          {field("work_start", t("settings.workStart"), "time")}
          {field("work_end", t("settings.workEnd"), "time")}
          {field("late_cutoff", t("settings.lateCutoff"), "time")}
          {field("lunch_minutes_allowed", t("settings.lunchAllowed"), "number", "1")}
          {field("lunch_minutes_red_threshold", t("settings.lunchRed"), "number", "1")}
        </div>
      </Card>

      <Card className="gap-4">
        <h3 className="px-1 text-sm font-semibold text-text">{t("settings.groups.discounts")}</h3>
        <div className="grid grid-cols-2 gap-3 px-1 sm:grid-cols-3">
          {field("discount_tech_max", t("settings.discountTechMax"), "number", "0.5")}
          {field("discount_admin_max", t("settings.discountAdminMax"), "number", "0.5")}
          {field("gst_rate", t("settings.gstRate"), "number", "0.5")}
        </div>
        <p className="px-1 text-xs text-text-muted">{t("settings.discountAbsoluteNote")}</p>
      </Card>

      <Card className="gap-4">
        <h3 className="px-1 text-sm font-semibold text-text">{t("settings.groups.sla")}</h3>
        <div className="grid grid-cols-2 gap-3 px-1 sm:grid-cols-3">
          {field("sla_hours_very_urgent", t("settings.slaVeryUrgent"), "number", "0.5")}
          {field("sla_hours_urgent", t("settings.slaUrgent"), "number", "0.5")}
          {field("sla_hours_normal", t("settings.slaNormal"), "number", "0.5")}
        </div>
      </Card>

      <Card className="gap-4">
        <h3 className="px-1 text-sm font-semibold text-text">{t("settings.groups.amcReferral")}</h3>
        <div className="grid grid-cols-2 gap-3 px-1 sm:grid-cols-3">
          {field("amc_book_window_days", t("settings.amcBookWindow"), "number", "1")}
          {field("referral_point_value", t("settings.referralPointValue"), "number", "1")}
          {field("review_link_min_stars", t("settings.reviewLinkMinStars"), "number", "0.5")}
        </div>
      </Card>

      <Card className="gap-4">
        <h3 className="px-1 text-sm font-semibold text-text">{t("settings.groups.inventory")}</h3>
        <div className="grid grid-cols-2 gap-3 px-1 sm:grid-cols-3">
          {field("default_min_stock", t("settings.defaultMinStock"), "number", "1")}
          {field("default_reorder_qty", t("settings.defaultReorderQty"), "number", "1")}
        </div>
      </Card>

      {updateMut.isError ? (
        <p className="rounded-xl bg-danger/10 px-3.5 py-2.5 text-sm text-danger">{(updateMut.error as Error).message}</p>
      ) : null}
      {updateMut.isSuccess ? (
        <p className="rounded-xl bg-success/10 px-3.5 py-2.5 text-sm text-success">{t("settings.saved")}</p>
      ) : null}

      <div className="flex justify-end">
        <Button type="submit" disabled={!isDirty || updateMut.isPending}>
          {updateMut.isPending ? <Loader2 className="size-4 animate-spin" /> : t("common.save")}
        </Button>
      </div>
    </form>
  )
}
