import { useEffect, useState } from "react"
import { useTranslation } from "react-i18next"
import { useForm } from "react-hook-form"
import { zodResolver } from "@hookform/resolvers/zod"
import { Loader2 } from "lucide-react"
import { Card } from "@/components/ui/card"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { Button } from "@/components/ui/button"
import { FullPageError, FullPageLoader } from "@/components/shared/FullPageLoader"
import { giftsHooks, useSettings, useUpdateSettings } from "@/hooks/useMasters"
import type { GiftRow } from "@/services/masters"
import { useProfile } from "@/hooks/useProfile"
import { settingsSchema, type SettingsFormInput, type SettingsOutput } from "@/lib/validation/settings"
import { cn } from "@/lib/utils"

function hhmm(value: string) {
  return value.slice(0, 5)
}

/** "4.5" stays "4.5", "5" stays "5" — mirrors the design's stepper labels, which never show trailing zeros. */
function formatPct(n: number) {
  return Number.isInteger(n) ? String(n) : n.toFixed(1)
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
    watch,
    setValue,
    formState: { errors, isDirty },
  } = useForm<SettingsFormInput, unknown, SettingsOutput>({ resolver: zodResolver(settingsSchema), mode: "onChange" })

  useEffect(() => {
    if (settings) {
      reset({
        per_km_minutes: Number(settings.per_km_minutes),
        geofence_radius_m: settings.geofence_radius_m,
        office_lat: Number(settings.office_lat),
        office_lng: Number(settings.office_lng),
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
        google_review_url: settings.google_review_url ?? "",
        default_min_stock: settings.default_min_stock,
        gst_rate: Number(settings.gst_rate),
        sla_hours_very_urgent: Number(settings.sla_hours_very_urgent),
        sla_hours_urgent: Number(settings.sla_hours_urgent),
        sla_hours_normal: Number(settings.sla_hours_normal),
        default_duration_paid_minutes: settings.default_duration_paid_minutes,
        default_duration_warranty_minutes: settings.default_duration_warranty_minutes,
        default_duration_amc_minutes: settings.default_duration_amc_minutes,
        default_duration_installation_minutes: settings.default_duration_installation_minutes,
        narrow_window_threshold_minutes: settings.narrow_window_threshold_minutes,
        po_approval_threshold: Number(settings.po_approval_threshold),
        po_requires_approval: settings.po_requires_approval,
        po_quote_timeout_hours: Number(settings.po_quote_timeout_hours),
        review_time_allowance_minutes: settings.review_time_allowance_minutes,
        enquiry_time_allowance_minutes: settings.enquiry_time_allowance_minutes,
      })
    }
  }, [settings, reset])

  if (isLoading) return <FullPageLoader label={t("common.loading")} />
  if (isError || !settings) {
    return <FullPageError message={t("masters.loadFailed")} onRetry={() => refetch()} retryLabel={t("common.retry")} />
  }

  const onSubmit = handleSubmit((values) => updateMut.mutate(values))

  const techMax = Number((watch("discount_tech_max") as number | string | undefined) ?? settings.discount_tech_max)
  const adminMax = Number((watch("discount_admin_max") as number | string | undefined) ?? settings.discount_admin_max)

  function stepTech(delta: number) {
    const next = Math.min(adminMax, Math.max(0, Math.round((techMax + delta) * 10) / 10))
    setValue("discount_tech_max", next, { shouldDirty: true, shouldValidate: true })
  }
  function stepAdmin(delta: number) {
    const next = Math.min(100, Math.max(techMax, Math.round((adminMax + delta) * 10) / 10))
    setValue("discount_admin_max", next, { shouldDirty: true, shouldValidate: true })
  }

  const field = (key: keyof SettingsFormInput, label: string, type: "number" | "time" | "text", step?: string, placeholder?: string) => (
    <div className="space-y-1">
      <Label htmlFor={key}>{label}</Label>
      <Input id={key} type={type} step={step} placeholder={placeholder} aria-invalid={!!errors[key]} {...register(key)} />
      {errors[key] ? <p className="text-xs text-danger">{t(errors[key]!.message!)}</p> : null}
    </div>
  )

  return (
    <form onSubmit={onSubmit} className="space-y-4">
      <DiscountGiftCard
        techMax={techMax}
        adminMax={adminMax}
        onStepTech={stepTech}
        onStepAdmin={stepAdmin}
        adminErrorMessage={errors.discount_admin_max?.message}
        onSaveLimits={onSubmit}
        saving={updateMut.isPending}
        orgId={orgId}
      />

      <Card className="gap-4">
        <h3 className="px-1 text-sm font-semibold text-text">{t("settings.groups.travel")}</h3>
        <div className="grid grid-cols-2 gap-3 px-1 sm:grid-cols-3">
          {field("per_km_minutes", t("settings.perKmMinutes"), "number", "0.5")}
          {field("geofence_radius_m", t("settings.geofenceRadius"), "number", "1")}
          {field("office_lat", t("settings.officeLat"), "number", "0.000001")}
          {field("office_lng", t("settings.officeLng"), "number", "0.000001")}
        </div>
        <p className="px-1 text-xs text-text-muted">{t("settings.officeLocationHint")}</p>
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
        <div className="grid grid-cols-2 gap-3 px-1 sm:grid-cols-3">{field("gst_rate", t("settings.gstRate"), "number", "0.5")}</div>
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
        <h3 className="px-1 text-sm font-semibold text-text">{t("settings.groups.jobDuration")}</h3>
        <div className="grid grid-cols-2 gap-3 px-1 sm:grid-cols-3">
          {field("default_duration_paid_minutes", t("settings.durationPaid"), "number", "1")}
          {field("default_duration_warranty_minutes", t("settings.durationWarranty"), "number", "1")}
          {field("default_duration_amc_minutes", t("settings.durationAmc"), "number", "1")}
          {field("default_duration_installation_minutes", t("settings.durationInstallation"), "number", "1")}
        </div>
        {/* GV.md 1.2: "if review time = 5 min, then estimated time + 5 min is
            shown as the technician's total allowed time (same logic for the
            enquiry allowance)." These stack on top of the type defaults
            above (or the job's actual item-time sum, once known — see
            src/lib/job-allowance.ts) rather than replacing them. */}
        <div className="grid grid-cols-2 gap-3 px-1 sm:grid-cols-3">
          {field("review_time_allowance_minutes", t("settings.reviewTimeAllowance"), "number", "1")}
          {field("enquiry_time_allowance_minutes", t("settings.enquiryTimeAllowance"), "number", "1")}
        </div>
        <p className="px-1 text-xs text-text-muted">{t("settings.allowanceHint")}</p>
      </Card>

      <Card className="gap-4">
        <h3 className="px-1 text-sm font-semibold text-text">{t("settings.groups.booking")}</h3>
        <div className="grid grid-cols-2 gap-3 px-1 sm:grid-cols-3">
          {field("narrow_window_threshold_minutes", t("settings.narrowWindowThreshold"), "number", "1")}
        </div>
        <p className="px-1 text-xs text-text-muted">{t("settings.narrowWindowThresholdHint")}</p>
      </Card>

      <Card className="gap-4">
        <h3 className="px-1 text-sm font-semibold text-text">{t("settings.groups.amcReferral")}</h3>
        <div className="grid grid-cols-2 gap-3 px-1 sm:grid-cols-3">
          {field("amc_book_window_days", t("settings.amcBookWindow"), "number", "1")}
          {field("referral_point_value", t("settings.referralPointValue"), "number", "1")}
          {field("review_link_min_stars", t("settings.reviewLinkMinStars"), "number", "0.5")}
        </div>
        <div className="px-1">
          {field("google_review_url", t("settings.googleReviewUrl"), "text", undefined, t("settings.googleReviewUrlPlaceholder"))}
          <p className="mt-1 text-xs text-text-muted">{t("settings.googleReviewUrlHint")}</p>
        </div>
      </Card>

      <Card className="gap-4">
        <h3 className="px-1 text-sm font-semibold text-text">{t("settings.groups.inventory")}</h3>
        <div className="grid grid-cols-2 gap-3 px-1 sm:grid-cols-3">
          {field("default_min_stock", t("settings.defaultMinStock"), "number", "1")}
          {field("po_approval_threshold", t("settings.poApprovalThreshold"), "number", "100")}
          {field("po_quote_timeout_hours", t("settings.poQuoteTimeoutHours"), "number", "1")}
        </div>
        <p className="px-1 text-xs text-text-muted">{t("settings.poQuoteTimeoutHoursHint")}</p>
        <label className="mx-1 flex items-center gap-2.5 rounded-xl border border-border bg-surface-alt px-3.5 py-2.5 text-sm text-text">
          <input type="checkbox" className="size-4 accent-accent" {...register("po_requires_approval")} />
          <span>
            <span className="block font-medium">{t("settings.poRequiresApproval")}</span>
            <span className="block text-xs text-text-muted">{t("settings.poRequiresApprovalHint")}</span>
          </span>
        </label>
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

// Matches design-template-decoded.html line 1281-1295 ("Discount & Gift Limits"):
// green self-approve / amber needs-approval / red blocked-above cards with
// stepper controls, plus a free-gift-threshold row. discTech/discAdmin map to
// the real settings.discount_tech_max / discount_admin_max fields (already
// part of the surrounding form's react-hook-form state — the steppers just
// call setValue instead of rendering a native <input>). "Blocked above" has
// no stepper because it isn't a stored value: it's admin_max itself, reframed
// as the ceiling nothing may cross (see settings.discountAbsoluteNote).
function DiscountGiftCard({
  techMax,
  adminMax,
  onStepTech,
  onStepAdmin,
  adminErrorMessage,
  onSaveLimits,
  saving,
  orgId,
}: {
  techMax: number
  adminMax: number
  onStepTech: (delta: number) => void
  onStepAdmin: (delta: number) => void
  adminErrorMessage?: string
  onSaveLimits: () => void
  saving: boolean
  orgId: string | undefined
}) {
  const { t } = useTranslation()

  return (
    <div className="rounded-card border border-border bg-surface p-6 shadow-[0_1px_2px_rgba(26,26,26,.04),0_14px_30px_-22px_rgba(26,26,26,.16)]">
      <div className="mb-4.5 flex flex-wrap items-center justify-between gap-2">
        <h3 className="text-[17px] font-bold tracking-tight text-text">{t("settings.discountGift.title")}</h3>
        <span className="rounded-full border border-border bg-surface-alt px-2.75 py-1.25 text-[11px] font-semibold text-text-muted">
          {t("settings.discountGift.auditLogged")}
        </span>
      </div>

      <div className="mb-3.5 grid grid-cols-1 gap-3.5 sm:grid-cols-3">
        <div className="rounded-subcard bg-[#E2F3EA] p-4.5">
          <div className="mb-2.5 text-xs font-semibold text-[#16855B]">{t("settings.discountGift.selfApprove")}</div>
          <div className="flex items-center justify-between">
            <StepperButton onClick={() => onStepTech(-1)} className="bg-[rgba(22,133,91,.18)] text-[#16855B]" label="−" ariaLabel="-" />
            <div className="text-[22px] font-extrabold tracking-[-0.02em] tabular-nums text-[#16855B]">{t("settings.discountGift.upTo", { value: formatPct(techMax) })}</div>
            <StepperButton onClick={() => onStepTech(1)} className="bg-[rgba(22,133,91,.18)] text-[#16855B]" label="+" ariaLabel="+" />
          </div>
        </div>

        <div className="rounded-subcard bg-[#FCF1DF] p-4.5">
          <div className="mb-2.5 text-xs font-semibold text-warning">{t("settings.discountGift.needsApproval")}</div>
          <div className="flex items-center justify-between">
            <StepperButton onClick={() => onStepAdmin(-1)} className="bg-[rgba(232,147,43,.20)] text-warning" label="−" ariaLabel="-" />
            <div className="text-[19px] font-extrabold tracking-[-0.02em] tabular-nums text-warning">
              {t("settings.discountGift.rangeLabel", { from: formatPct(techMax), to: formatPct(adminMax) })}
            </div>
            <StepperButton onClick={() => onStepAdmin(1)} className="bg-[rgba(232,147,43,.20)] text-warning" label="+" ariaLabel="+" />
          </div>
          {adminErrorMessage ? <p className="mt-2 text-[11px] font-medium text-danger">{t(adminErrorMessage)}</p> : null}
        </div>

        <div className="rounded-subcard bg-[#FCEAEA] p-4.5">
          <div className="mb-2.5 text-xs font-semibold text-danger">{t("settings.discountGift.blockedAbove")}</div>
          <div className="flex h-7.5 items-center justify-center">
            <div className="text-[22px] font-extrabold tracking-[-0.02em] tabular-nums text-danger">{t("settings.discountGift.above", { value: formatPct(adminMax) })}</div>
          </div>
        </div>
      </div>

      <p className="mb-3.5 px-0.5 text-xs text-text-muted">{t("settings.discountAbsoluteNote")}</p>

      <GiftThresholdRow orgId={orgId} onSaveLimits={onSaveLimits} savingLimits={saving} />
    </div>
  )
}

function StepperButton({ onClick, className, label, ariaLabel }: { onClick: () => void; className: string; label: string; ariaLabel: string }) {
  return (
    <button
      type="button"
      onClick={onClick}
      aria-label={ariaLabel}
      className={cn("flex size-7.5 shrink-0 items-center justify-center rounded-[9px] text-base font-extrabold", className)}
    >
      {label}
    </button>
  )
}

// The design's single scalar "free gift threshold" doesn't exist as its own
// settings column — gifts are a real multi-tier table (masters.ts listGifts,
// already ordered ascending by threshold_amount). The entry-level (lowest
// threshold) gift is exactly the one that "auto-suggests a gift" once an
// invoice crosses it, so that's what this row edits — a real row via the same
// giftsHooks.useUpdate mutation the Gifts tab uses (audit-logged the same
// way). If no gift tiers exist yet, we say so instead of fabricating one.
function GiftThresholdRow({
  orgId,
  onSaveLimits,
  savingLimits,
}: {
  orgId: string | undefined
  onSaveLimits: () => void
  savingLimits: boolean
}) {
  const { t } = useTranslation()
  const { data: gifts, isLoading } = giftsHooks.useList(orgId)
  const updateGiftMut = giftsHooks.useUpdate()

  const entryGift: GiftRow | null = gifts && gifts.length > 0 ? gifts[0] : null
  const [localThreshold, setLocalThreshold] = useState<number | null>(null)

  useEffect(() => {
    if (entryGift) setLocalThreshold(entryGift.threshold_amount)
  }, [entryGift])

  if (isLoading) {
    return <div className="h-16 animate-pulse rounded-subcard bg-surface-alt" />
  }

  if (!entryGift || localThreshold === null) {
    return <div className="rounded-subcard border border-border bg-surface-alt px-4.5 py-3.5 text-xs font-medium text-text-muted">{t("settings.discountGift.noGifts")}</div>
  }

  const giftDirty = localThreshold !== entryGift.threshold_amount

  return (
    <div className="flex flex-wrap items-center gap-3.5 rounded-subcard border border-border bg-surface-alt px-4.5 py-3.5">
      <div className="min-w-[160px] flex-1">
        <div className="text-[13px] font-bold text-text">{t("settings.discountGift.freeGiftThreshold")}</div>
        <div className="text-[11px] font-medium text-text-muted">{t("settings.discountGift.freeGiftThresholdDesc", { name: entryGift.name })}</div>
      </div>
      <StepperButton
        onClick={() => setLocalThreshold((v) => Math.max(0, (v ?? 0) - 500))}
        className="border border-[#DAD5CC] bg-surface text-text"
        label="−"
        ariaLabel="-"
      />
      <div className="min-w-[88px] text-center text-[18px] font-extrabold tabular-nums text-text">₹{localThreshold.toLocaleString("en-IN")}</div>
      <StepperButton onClick={() => setLocalThreshold((v) => (v ?? 0) + 500)} className="border border-[#DAD5CC] bg-surface text-text" label="+" ariaLabel="+" />
      <button
        type="button"
        disabled={savingLimits || updateGiftMut.isPending}
        onClick={() => {
          if (giftDirty) updateGiftMut.mutate({ id: entryGift.id, patch: { threshold_amount: localThreshold } })
          onSaveLimits()
        }}
        className="rounded-full bg-ink px-5 py-2.75 text-[13px] font-bold text-white shadow-[0_10px_20px_-12px_rgba(26,26,26,0.6)] disabled:opacity-50"
      >
        {savingLimits || updateGiftMut.isPending ? <Loader2 className="mx-auto size-4 animate-spin" /> : t("settings.discountGift.saveLimits")}
      </button>
    </div>
  )
}
