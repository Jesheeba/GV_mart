import { useCallback, useEffect, useState } from "react"
import { useTranslation } from "react-i18next"
import { useForm } from "react-hook-form"
import { zodResolver } from "@hookform/resolvers/zod"
import { Loader2 } from "lucide-react"
import { Card } from "@/components/ui/card"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { Button } from "@/components/ui/button"
import { FullPageError, FullPageLoader } from "@/components/shared/FullPageLoader"
import { UnsavedChangesGuard } from "@/components/shared/UnsavedChangesGuard"
import { giftsHooks, useSettings, useUpdateSettings } from "@/hooks/useMasters"
import type { GiftRow } from "@/services/masters"
import { useProfile } from "@/hooks/useProfile"
import { useOrganization, useUpdateOrganization } from "@/hooks/useSales"
import { settingsSchema, type SettingsFormInput, type SettingsOutput } from "@/lib/validation/settings"
import { cn } from "@/lib/utils"
import { AppointmentSlotsCard } from "./AppointmentSlotsCard"
import { AutoAssignLeadsCard } from "./AutoAssignLeadsCard"

function hhmm(value: string) {
  return value.slice(0, 5)
}

/** "4.5" stays "4.5", "5" stays "5" — mirrors the design's stepper labels, which never show trailing zeros. */
function formatPct(n: number) {
  return Number.isInteger(n) ? String(n) : n.toFixed(1)
}

/**
 * Pre-coercion (SettingsFormInput-shaped) view of the saved settings row —
 * shared by the initial `reset()` and by every per-group save as the
 * "everything except this group" baseline. Centralized so a per-group save
 * builds its payload from the exact same mapping the form was last
 * initialized from, not a second hand-maintained copy of it.
 */
function toFormValues(settings: NonNullable<ReturnType<typeof useSettings>["data"]>): SettingsFormInput {
  return {
    per_km_minutes: Number(settings.per_km_minutes),
    geofence_radius_m: settings.geofence_radius_m,
    geofence_radius_job_m: settings.geofence_radius_job_m,
    office_lat: Number(settings.office_lat),
    office_lng: Number(settings.office_lng),
    work_start: hhmm(settings.work_start),
    work_end: hhmm(settings.work_end),
    late_cutoff: hhmm(settings.late_cutoff),
    very_late_threshold_minutes: settings.very_late_threshold_minutes,
    lunch_minutes_allowed: settings.lunch_minutes_allowed,
    lunch_minutes_red_threshold: settings.lunch_minutes_red_threshold,
    discount_tech_max: Number(settings.discount_tech_max),
    discount_admin_max: Number(settings.discount_admin_max),
    amc_book_window_days: settings.amc_book_window_days,
    referral_point_value: Number(settings.referral_point_value),
    review_link_min_stars: Number(settings.review_link_min_stars),
    google_review_url: settings.google_review_url ?? "",
    review_flag_threshold_percent: Number(settings.review_flag_threshold_percent),
    review_flag_min_visits: settings.review_flag_min_visits,
    default_min_stock: settings.default_min_stock,
    gst_rate: Number(settings.gst_rate),
    sla_hours_very_urgent: Number(settings.sla_hours_very_urgent),
    sla_hours_urgent: Number(settings.sla_hours_urgent),
    sla_hours_normal: Number(settings.sla_hours_normal),
    default_duration_paid_minutes: settings.default_duration_paid_minutes,
    default_duration_warranty_minutes: settings.default_duration_warranty_minutes,
    default_duration_amc_minutes: settings.default_duration_amc_minutes,
    default_duration_installation_minutes: settings.default_duration_installation_minutes,
    job_overrun_buffer_minutes: settings.job_overrun_buffer_minutes,
    ops_resolution_sla_hours: settings.ops_resolution_sla_hours,
    narrow_window_threshold_minutes: settings.narrow_window_threshold_minutes,
    po_approval_threshold: Number(settings.po_approval_threshold),
    po_requires_approval: settings.po_requires_approval,
    po_quote_timeout_hours: Number(settings.po_quote_timeout_hours),
    po_quote_day_of_month: settings.po_quote_day_of_month ?? "",
    review_time_allowance_minutes: settings.review_time_allowance_minutes,
    enquiry_time_allowance_minutes: settings.enquiry_time_allowance_minutes,
    emi_enabled: settings.emi_enabled,
    review_incentives_enabled: settings.review_incentives_enabled,
    emi_tenure_months: (Array.isArray(settings.emi_tenure_months) ? settings.emi_tenure_months : []).join(","),
    emi_disclaimer: settings.emi_disclaimer ?? "",
  }
}

// One row per <Card> below that holds fields from the big form. Lets a
// group's Save button submit *only* its own fields (see saveGroup) instead
// of silently also committing whatever else happens to be dirty elsewhere
// on the page (MASTER-001's actual root cause — 15 groups sharing 3 Save
// buttons, not just 3 buttons being hard to find).
const FIELD_GROUPS = {
  discountGift: ["discount_tech_max", "discount_admin_max"],
  travel: ["per_km_minutes", "geofence_radius_m", "geofence_radius_job_m", "office_lat", "office_lng"],
  attendance: ["work_start", "work_end", "late_cutoff", "very_late_threshold_minutes", "lunch_minutes_allowed", "lunch_minutes_red_threshold"],
  gst: ["gst_rate"],
  sla: ["sla_hours_very_urgent", "sla_hours_urgent", "sla_hours_normal"],
  jobDuration: [
    "default_duration_paid_minutes",
    "default_duration_warranty_minutes",
    "default_duration_amc_minutes",
    "default_duration_installation_minutes",
    "review_time_allowance_minutes",
    "enquiry_time_allowance_minutes",
    "job_overrun_buffer_minutes",
    "ops_resolution_sla_hours",
  ],
  booking: ["narrow_window_threshold_minutes"],
  amcReferral: [
    "amc_book_window_days",
    "referral_point_value",
    "review_link_min_stars",
    "google_review_url",
    "review_flag_threshold_percent",
    "review_flag_min_visits",
    "review_incentives_enabled",
  ],
  inventory: ["default_min_stock", "po_approval_threshold", "po_quote_timeout_hours", "po_quote_day_of_month", "po_requires_approval"],
  productEnquiry: ["emi_tenure_months", "emi_disclaimer", "emi_enabled"],
} as const satisfies Record<string, readonly (keyof SettingsFormInput)[]>

type GroupKey = keyof typeof FIELD_GROUPS

export function SettingsTab() {
  const { t } = useTranslation()
  const { data: profile } = useProfile()
  const orgId = profile?.org_id
  const { data: settings, isLoading, isError, refetch } = useSettings(orgId)
  const updateMut = useUpdateSettings(orgId)
  const [savingGroup, setSavingGroup] = useState<GroupKey | null>(null)
  const [justSavedGroup, setJustSavedGroup] = useState<GroupKey | null>(null)
  const [orgProfileDirty, setOrgProfileDirty] = useState(false)
  const handleOrgProfileDirtyChange = useCallback((dirty: boolean) => setOrgProfileDirty(dirty), [])

  const {
    register,
    handleSubmit,
    reset,
    watch,
    getValues,
    trigger,
    setValue,
    formState: { errors, isDirty, dirtyFields },
  } = useForm<SettingsFormInput, unknown, SettingsOutput>({ resolver: zodResolver(settingsSchema), mode: "onChange" })

  useEffect(() => {
    // `keepDirtyValues` matters here, not just on the per-group save path
    // below: without it, *any* settings refetch (another group's save,
    // another admin's edit landing via a slow network retry, React Query's
    // own background refetch) would silently blow away whatever the user is
    // still mid-typing in an untouched field elsewhere on this long page.
    if (settings) reset(toFormValues(settings), { keepDirtyValues: true })
  }, [settings, reset])

  if (isLoading) return <FullPageLoader label={t("common.loading")} />
  if (isError || !settings) {
    return <FullPageError message={t("masters.loadFailed")} onRetry={() => refetch()} retryLabel={t("common.retry")} />
  }

  const onSubmit = handleSubmit((values) => updateMut.mutate(values))

  /**
   * Scoped save for one Card: validates only that group's fields (every
   * cross-field `.refine()` in settingsSchema happens to compare fields
   * within the same group, so this never spuriously blocks on an unrelated
   * group's in-progress edit), then submits a payload built from the last
   * known server truth overlaid with *only* this group's live values — so a
   * dirty, unsaved edit sitting in a different card is neither lost nor
   * accidentally persisted as a side effect of clicking this button.
   */
  async function saveGroup(key: GroupKey) {
    const fieldKeys = FIELD_GROUPS[key]
    const valid = await trigger(fieldKeys as unknown as (keyof SettingsFormInput)[])
    if (!valid) return
    const merged: SettingsFormInput = { ...toFormValues(settings!), ...pick(getValues(), fieldKeys) }
    setSavingGroup(key)
    try {
      await updateMut.mutateAsync(settingsSchema.parse(merged))
      // keepDirtyValues again: saving the Travel card shouldn't revert a
      // still-unsaved edit sitting in the Inventory card two scrolls away.
      reset(merged, { keepDirtyValues: true })
      setJustSavedGroup(key)
    } finally {
      setSavingGroup(null)
    }
  }

  function pick<T extends Record<string, unknown>>(obj: T, keys: readonly (keyof T)[]): Partial<T> {
    const out: Partial<T> = {}
    for (const k of keys) out[k] = obj[k]
    return out
  }

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
      <Input
        id={key}
        type={type}
        step={step}
        placeholder={placeholder}
        aria-invalid={!!errors[key]}
        {...register(key, { onChange: () => setJustSavedGroup(null) })}
      />
      {errors[key] ? <p className="text-xs text-danger">{t(errors[key]!.message!)}</p> : null}
    </div>
  )

  function isGroupDirty(key: GroupKey) {
    return FIELD_GROUPS[key].some((k) => dirtyFields[k as keyof SettingsFormInput])
  }

  function GroupSaveRow({ groupKey }: { groupKey: GroupKey }) {
    const dirty = isGroupDirty(groupKey)
    return (
      <div className="flex items-center justify-end gap-2 px-1">
        {justSavedGroup === groupKey && !dirty ? <span className="text-xs text-success">{t("settings.saved")}</span> : null}
        <Button type="button" size="sm" disabled={!dirty || savingGroup === groupKey} onClick={() => saveGroup(groupKey)}>
          {savingGroup === groupKey ? <Loader2 className="size-4 animate-spin" /> : t("common.save")}
        </Button>
      </div>
    )
  }

  return (
    <form onSubmit={onSubmit} className={cn("space-y-4", (isDirty || updateMut.isSuccess) && "pb-20")}>
      <UnsavedChangesGuard when={isDirty || orgProfileDirty} />
      <OrgProfileCard orgId={orgId} onDirtyChange={handleOrgProfileDirtyChange} />

      <DiscountGiftCard
        techMax={techMax}
        adminMax={adminMax}
        onStepTech={stepTech}
        onStepAdmin={stepAdmin}
        adminErrorMessage={errors.discount_admin_max?.message}
        onSaveLimits={() => saveGroup("discountGift")}
        saving={savingGroup === "discountGift"}
        orgId={orgId}
      />

      <Card className="gap-4">
        <h3 className="px-1 text-sm font-semibold text-text">{t("settings.groups.travel")}</h3>
        <div className="grid grid-cols-2 gap-3 px-1 sm:grid-cols-3">
          {field("per_km_minutes", t("settings.perKmMinutes"), "number", "0.5")}
          {field("geofence_radius_m", t("settings.geofenceRadius"), "number", "1")}
          {field("geofence_radius_job_m", t("settings.geofenceRadiusJob"), "number", "1")}
          {field("office_lat", t("settings.officeLat"), "number", "0.000001")}
          {field("office_lng", t("settings.officeLng"), "number", "0.000001")}
        </div>
        <p className="px-1 text-xs text-text-muted">{t("settings.officeLocationHint")}</p>
        <GroupSaveRow groupKey="travel" />
      </Card>

      <Card className="gap-4">
        <h3 className="px-1 text-sm font-semibold text-text">{t("settings.groups.attendance")}</h3>
        <div className="grid grid-cols-2 gap-3 px-1 sm:grid-cols-3">
          {field("work_start", t("settings.workStart"), "time")}
          {field("work_end", t("settings.workEnd"), "time")}
          {field("late_cutoff", t("settings.lateCutoff"), "time")}
          {field("very_late_threshold_minutes", t("settings.veryLateThreshold"), "number", "1")}
          {field("lunch_minutes_allowed", t("settings.lunchAllowed"), "number", "1")}
          {field("lunch_minutes_red_threshold", t("settings.lunchRed"), "number", "1")}
        </div>
        <p className="px-1 text-xs text-text-muted">{t("settings.attendanceStatusHint")}</p>
        <GroupSaveRow groupKey="attendance" />
      </Card>

      <Card className="gap-4">
        <h3 className="px-1 text-sm font-semibold text-text">{t("settings.groups.discounts")}</h3>
        <div className="grid grid-cols-2 gap-3 px-1 sm:grid-cols-3">{field("gst_rate", t("settings.gstRate"), "number", "0.5")}</div>
        <GroupSaveRow groupKey="gst" />
      </Card>

      <Card className="gap-4">
        <h3 className="px-1 text-sm font-semibold text-text">{t("settings.groups.sla")}</h3>
        <div className="grid grid-cols-2 gap-3 px-1 sm:grid-cols-3">
          {field("sla_hours_very_urgent", t("settings.slaVeryUrgent"), "number", "0.5")}
          {field("sla_hours_urgent", t("settings.slaUrgent"), "number", "0.5")}
          {field("sla_hours_normal", t("settings.slaNormal"), "number", "0.5")}
        </div>
        <GroupSaveRow groupKey="sla" />
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
        <div className="grid grid-cols-2 gap-3 px-1 sm:grid-cols-3">
          {field("job_overrun_buffer_minutes", t("settings.jobOverrunBuffer"), "number", "1")}
          {field("ops_resolution_sla_hours", t("settings.opsResolutionSla"), "number", "1")}
        </div>
        <p className="px-1 text-xs text-text-muted">{t("settings.overrunSlaHint")}</p>
        <GroupSaveRow groupKey="jobDuration" />
      </Card>

      <Card className="gap-4">
        <h3 className="px-1 text-sm font-semibold text-text">{t("settings.groups.booking")}</h3>
        <div className="grid grid-cols-2 gap-3 px-1 sm:grid-cols-3">
          {field("narrow_window_threshold_minutes", t("settings.narrowWindowThreshold"), "number", "1")}
        </div>
        <p className="px-1 text-xs text-text-muted">{t("settings.narrowWindowThresholdHint")}</p>
        <GroupSaveRow groupKey="booking" />
      </Card>

      {/* AutoAssignLeadsCard and AppointmentSlotsCard deliberately get no
          GroupSaveRow: AutoAssignLeadsCard's toggle persists immediately on
          change (its own mutation, no draft state to lose), and
          AppointmentSlotsCard is a CRUD list where every add/edit already
          submits through its own explicit per-row Save in its dialog. A
          per-group Save button here would be misleading — there is never
          anything pending to commit. */}
      <AutoAssignLeadsCard />
      <AppointmentSlotsCard />

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
        <div className="grid grid-cols-2 gap-3 px-1">
          {field("review_flag_threshold_percent", t("settings.reviewFlagThresholdPercent"), "number", "1")}
          {field("review_flag_min_visits", t("settings.reviewFlagMinVisits"), "number", "1")}
        </div>
        <p className="px-1 text-xs text-text-muted">{t("settings.reviewFlagHint")}</p>
        <label className="mx-1 flex items-center gap-2.5 rounded-xl border border-border bg-surface-alt px-3.5 py-2.5 text-sm text-text">
          <input type="checkbox" className="size-4 accent-accent" {...register("review_incentives_enabled", { onChange: () => setJustSavedGroup(null) })} />
          <span>
            <span className="block font-medium">{t("settings.reviewIncentivesEnabled")}</span>
            <span className="block text-xs text-text-muted">{t("settings.reviewIncentivesEnabledHint")}</span>
          </span>
        </label>
        <GroupSaveRow groupKey="amcReferral" />
      </Card>

      <Card className="gap-4">
        <h3 className="px-1 text-sm font-semibold text-text">{t("settings.groups.inventory")}</h3>
        <div className="grid grid-cols-2 gap-3 px-1 sm:grid-cols-3">
          {field("default_min_stock", t("settings.defaultMinStock"), "number", "1")}
          {field("po_approval_threshold", t("settings.poApprovalThreshold"), "number", "100")}
          {field("po_quote_timeout_hours", t("settings.poQuoteTimeoutHours"), "number", "1")}
        </div>
        <p className="px-1 text-xs text-text-muted">{t("settings.poQuoteTimeoutHoursHint")}</p>
        <div className="grid grid-cols-2 gap-3 px-1 sm:grid-cols-3">
          {field("po_quote_day_of_month", t("settings.poQuoteDayOfMonth"), "number", "1")}
        </div>
        <p className="px-1 text-xs text-text-muted">{t("settings.poQuoteDayOfMonthHint")}</p>
        <label className="mx-1 flex items-center gap-2.5 rounded-xl border border-border bg-surface-alt px-3.5 py-2.5 text-sm text-text">
          <input type="checkbox" className="size-4 accent-accent" {...register("po_requires_approval", { onChange: () => setJustSavedGroup(null) })} />
          <span>
            <span className="block font-medium">{t("settings.poRequiresApproval")}</span>
            <span className="block text-xs text-text-muted">{t("settings.poRequiresApprovalHint")}</span>
          </span>
        </label>
        <GroupSaveRow groupKey="inventory" />
      </Card>

      <Card className="gap-4">
        <h3 className="px-1 text-sm font-semibold text-text">{t("settings.groups.productEnquiry")}</h3>
        <div className="px-1">
          {field("emi_tenure_months", t("settings.emiTenureMonths"), "text", undefined, t("settings.emiTenureMonthsPlaceholder"))}
          <p className="mt-1 text-xs text-text-muted">{t("settings.emiTenureMonthsHint")}</p>
        </div>
        <div className="px-1">{field("emi_disclaimer", t("settings.emiDisclaimer"), "text", undefined, t("settings.emiDisclaimerPlaceholder"))}</div>
        <label className="mx-1 flex items-center gap-2.5 rounded-xl border border-border bg-surface-alt px-3.5 py-2.5 text-sm text-text">
          <input type="checkbox" className="size-4 accent-accent" {...register("emi_enabled", { onChange: () => setJustSavedGroup(null) })} />
          <span>
            <span className="block font-medium">{t("settings.emiEnabled")}</span>
            <span className="block text-xs text-text-muted">{t("settings.emiEnabledHint")}</span>
          </span>
        </label>
        <GroupSaveRow groupKey="productEnquiry" />
      </Card>

      {updateMut.isError ? (
        <p className="rounded-xl bg-danger/10 px-3.5 py-2.5 text-sm text-danger">{(updateMut.error as Error).message}</p>
      ) : null}

      {/* Every group above now has its own scoped Save, so this bar is no
          longer "the only way to save anything" (MASTER-001's original
          failure mode) — it's a convenience for committing every dirty
          group in one action, clearly labeled as such, plus the generic
          "something here is unsaved" signal SettingsNavigationGuard listens
          for isn't itself visible on screen. Still `fixed`, not `sticky`,
          for the same reason as before: `sticky`'s own flow position in a
          page this long means it wouldn't appear until scrolled almost to
          the bottom anyway. */}
      {isDirty || updateMut.isSuccess ? (
        <div className="fixed inset-x-0 bottom-4 z-20 flex justify-center px-4 sm:left-[88px] sm:right-6 sm:justify-end">
          <div className="flex w-full max-w-md items-center justify-between gap-3 rounded-card border border-border bg-surface px-4 py-3 shadow-[0_8px_30px_-12px_rgba(26,26,26,0.35)]">
            <p className="text-sm font-medium text-text">{isDirty ? t("settings.unsavedChangesBar") : t("settings.saved")}</p>
            <Button type="submit" disabled={!isDirty || updateMut.isPending}>
              {updateMut.isPending ? <Loader2 className="size-4 animate-spin" /> : t("settings.saveAll")}
            </Button>
          </div>
        </div>
      ) : null}
    </form>
  )
}

// The org's letterhead info (GSTIN/address/phone) has no other settings home —
// it's stored on organizations, not the app_settings row the rest of this
// page edits, so it gets its own small local form + mutation instead of
// joining the big react-hook-form above.
function OrgProfileCard({ orgId, onDirtyChange }: { orgId: string | undefined; onDirtyChange: (dirty: boolean) => void }) {
  const { t } = useTranslation()
  const { data: org, isLoading } = useOrganization(orgId)
  const updateMut = useUpdateOrganization(orgId)

  const [gstNo, setGstNo] = useState("")
  const [address, setAddress] = useState("")
  const [phone, setPhone] = useState("")
  const [businessHours, setBusinessHours] = useState("")

  useEffect(() => {
    if (org) {
      setGstNo(org.gst_no ?? "")
      setAddress(org.address ?? "")
      setPhone(org.phone ?? "")
      setBusinessHours(org.business_hours ?? "")
    }
  }, [org])

  const dirty = !!org && (gstNo !== (org.gst_no ?? "") || address !== (org.address ?? "") || phone !== (org.phone ?? "") || businessHours !== (org.business_hours ?? ""))

  // This card has its own local-state form (see the comment above), separate
  // from the big react-hook-form the rest of the page uses — so its dirty
  // state has to be reported up separately too, or the navigation guard at
  // the top of the page would miss edits made here specifically.
  useEffect(() => {
    onDirtyChange(dirty)
  }, [dirty, onDirtyChange])

  if (isLoading || !org) {
    return <div className="h-32 animate-pulse rounded-card border border-border bg-surface" />
  }

  return (
    <Card className="gap-4">
      <div>
        <h3 className="px-1 text-sm font-semibold text-text">{t("settings.orgProfile.title")}</h3>
        <p className="px-1 text-xs text-text-muted">{t("settings.orgProfile.hint")}</p>
      </div>
      <div className="grid grid-cols-1 gap-3 px-1 sm:grid-cols-3">
        <div className="space-y-1">
          <Label htmlFor="org-gst-no">{t("settings.orgProfile.gstNo")}</Label>
          <Input id="org-gst-no" value={gstNo} onChange={(e) => setGstNo(e.target.value)} />
        </div>
        <div className="space-y-1">
          <Label htmlFor="org-phone">{t("settings.orgProfile.phone")}</Label>
          <Input id="org-phone" value={phone} onChange={(e) => setPhone(e.target.value)} />
        </div>
        <div className="space-y-1 sm:col-span-1">
          <Label htmlFor="org-address">{t("settings.orgProfile.address")}</Label>
          <Input id="org-address" value={address} onChange={(e) => setAddress(e.target.value)} />
        </div>
      </div>
      <div className="px-1">
        <Label htmlFor="org-hours">{t("settings.orgProfile.hours")}</Label>
        <Input id="org-hours" value={businessHours} onChange={(e) => setBusinessHours(e.target.value)} placeholder={t("settings.orgProfile.hoursPlaceholder")} />
        <p className="mt-1 text-xs text-text-muted">{t("settings.orgProfile.hoursHint")}</p>
      </div>
      <div className="flex items-center justify-end gap-2 px-1">
        {updateMut.isSuccess && !dirty ? <span className="text-xs text-success">{t("settings.orgProfile.saved")}</span> : null}
        <Button
          type="button"
          disabled={!dirty || updateMut.isPending}
          onClick={() =>
            updateMut.mutate({ gst_no: gstNo || null, address: address || null, phone: phone || null, business_hours: businessHours || null })
          }
        >
          {updateMut.isPending ? <Loader2 className="size-4 animate-spin" /> : t("common.save")}
        </Button>
      </div>
    </Card>
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
      <div className="flex flex-col items-end gap-1">
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
        {/* This button has always saved the whole page's form, not just this
            card (see onSaveLimits) — that hint used to live only in a title=
            tooltip, invisible on touch and easy to miss on desktop, which was
            the real source of "which groups does Save actually cover?"
            confusion (MASTER-001). Printing it as a visible caption instead. */}
        <p className="max-w-[220px] text-right text-[10px] text-text-muted">{t("settings.discountGift.saveLimitsHint")}</p>
      </div>
    </div>
  )
}
