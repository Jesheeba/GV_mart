import { useState } from "react"
import { useTranslation } from "react-i18next"
import { zodResolver } from "@hookform/resolvers/zod"
import { useForm } from "react-hook-form"
import { Loader2, Pencil } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { SegButton } from "@/components/shared/SegButton"
import { useUpdateCustomerWaterProfile } from "@/hooks/useCustomers"
import { HEALTH_CONDITION_LEVELS, WATER_SOURCES, waterProfileSchema, type WaterProfileInput } from "@/lib/validation/customer"
import { formatDate } from "@/lib/formatDate"
import type { CustomerMeasuredWaterReading } from "@/services/waterQuality"

type WaterHouseholdPanelProps = {
  customerId: string
  waterSource: WaterProfileInput["waterSource"] | null
  waterSourceOther: string | null
  waterTdsPpm: number | null
  waterPh: number | null
  // undefined while the health_condition RPC is still loading — rendered as "—" the same as null,
  // just kept distinct in the type so a caller can tell "not loaded yet" from "not set/not visible".
  healthCondition: WaterProfileInput["healthCondition"] | null | undefined
  /** customer_members where moved_out_at is null — always derived, never a stored column. */
  familyMemberCount: number
  /** The latest ro_checklists reading from a real service visit (separate, untouched table). */
  measuredReading?: CustomerMeasuredWaterReading | null
  /** master/operation_admin only — see 20261108100000_customer_water_profile.sql. */
  canEdit: boolean
}

/**
 * Renders bare (no outer Card), same convention as FamilyMembersPanel — drops into
 * CustomerDetailPage's "Water & household" tab or a Card already provided by CustomerFormPage's
 * edit step without doubling up the border/shadow.
 */
export function WaterHouseholdPanel({
  customerId,
  waterSource,
  waterSourceOther,
  waterTdsPpm,
  waterPh,
  healthCondition,
  familyMemberCount,
  measuredReading,
  canEdit,
}: WaterHouseholdPanelProps) {
  const { t } = useTranslation()
  const [editing, setEditing] = useState(false)
  const updateProfile = useUpdateCustomerWaterProfile(customerId)

  const {
    register,
    handleSubmit,
    watch,
    setValue,
    formState: { errors },
  } = useForm<WaterProfileInput>({
    resolver: zodResolver(waterProfileSchema),
    mode: "onChange",
    defaultValues: {
      waterSource: waterSource ?? "",
      waterSourceOther: waterSourceOther ?? "",
      waterTdsPpm: waterTdsPpm ?? undefined,
      waterPh: waterPh ?? undefined,
      healthCondition: healthCondition ?? "",
    },
  })
  const watchedSource = watch("waterSource")

  const onSave = handleSubmit((values) => {
    updateProfile.mutate(
      {
        waterSource: values.waterSource || null,
        waterSourceOther: values.waterSource === "other" ? values.waterSourceOther?.trim() || null : null,
        waterTdsPpm: values.waterTdsPpm == null || Number.isNaN(values.waterTdsPpm) ? null : values.waterTdsPpm,
        waterPh: values.waterPh == null || Number.isNaN(values.waterPh) ? null : values.waterPh,
        healthCondition: values.healthCondition || null,
      },
      { onSuccess: () => setEditing(false) }
    )
  })

  if (editing) {
    return (
      <form onSubmit={onSave} className="space-y-3">
        <div className="space-y-1.5">
          <Label>{t("customers.detail.waterSource")}</Label>
          <div className="flex flex-wrap gap-1 rounded-full bg-surface-alt p-1">
            {WATER_SOURCES.map((s) => (
              <SegButton key={s} active={watchedSource === s} onClick={() => setValue("waterSource", s, { shouldValidate: true })}>
                {t(`customers.detail.waterSourceOptions.${s}`)}
              </SegButton>
            ))}
          </div>
        </div>
        {watchedSource === "other" ? (
          <div className="space-y-1.5">
            <Input placeholder={t("customers.detail.waterSourceOtherPlaceholder")} {...register("waterSourceOther")} />
            {errors.waterSourceOther ? <p className="text-xs text-danger">{t(errors.waterSourceOther.message!)}</p> : null}
          </div>
        ) : null}
        <div className="flex gap-2">
          <div className="flex-1 space-y-1.5">
            <Label htmlFor="waterTdsPpm">{t("customers.detail.waterTds")}</Label>
            <Input id="waterTdsPpm" type="number" step="1" min={0} aria-invalid={!!errors.waterTdsPpm} {...register("waterTdsPpm", { valueAsNumber: true })} />
            {errors.waterTdsPpm ? <p className="text-xs text-danger">{t(errors.waterTdsPpm.message!)}</p> : null}
          </div>
          <div className="flex-1 space-y-1.5">
            <Label htmlFor="waterPh">{t("customers.detail.waterPh")}</Label>
            <Input id="waterPh" type="number" step="0.1" min={0} max={14} aria-invalid={!!errors.waterPh} {...register("waterPh", { valueAsNumber: true })} />
            {errors.waterPh ? <p className="text-xs text-danger">{t(errors.waterPh.message!)}</p> : null}
          </div>
        </div>
        <div className="space-y-1.5">
          <Label htmlFor="healthCondition">{t("customers.detail.healthCondition")}</Label>
          <select
            id="healthCondition"
            defaultValue={healthCondition ?? ""}
            className="h-9 w-full rounded-xl border border-border bg-surface px-3 text-sm text-text outline-none"
            {...register("healthCondition")}
          >
            <option value="">{t("customers.detail.healthConditionPlaceholder")}</option>
            {HEALTH_CONDITION_LEVELS.map((level) => (
              <option key={level} value={level}>
                {t(`customers.detail.healthConditionLevels.${level}`)}
              </option>
            ))}
          </select>
        </div>
        {updateProfile.isError ? <p className="text-xs text-danger">{(updateProfile.error as Error).message}</p> : null}
        <div className="flex justify-end gap-2">
          <Button type="button" size="sm" variant="ghost" onClick={() => setEditing(false)}>
            {t("common.cancel")}
          </Button>
          <Button type="submit" size="sm" disabled={updateProfile.isPending}>
            {updateProfile.isPending ? <Loader2 className="size-3.5 animate-spin" /> : t("common.save")}
          </Button>
        </div>
      </form>
    )
  }

  return (
    <div className="space-y-3">
      <div className="flex items-center justify-between px-1">
        <h2 className="text-lg font-semibold text-text">{t("customers.detail.waterHouseholdTitle")}</h2>
        {canEdit ? (
          <Button size="sm" variant="outline" onClick={() => setEditing(true)}>
            <Pencil className="size-3.5" />
            {t("common.edit")}
          </Button>
        ) : null}
      </div>
      <div className="grid grid-cols-2 gap-y-2 px-1 text-sm">
        <span className="text-text-muted">{t("customers.detail.waterSource")}</span>
        <span className="text-text">
          {waterSource
            ? waterSource === "other" && waterSourceOther
              ? waterSourceOther
              : t(`customers.detail.waterSourceOptions.${waterSource}`)
            : "—"}
        </span>
        <span className="text-text-muted">{t("customers.detail.waterTds")}</span>
        <span className="text-text">{waterTdsPpm ?? "—"}</span>
        <span className="text-text-muted">{t("customers.detail.waterPh")}</span>
        <span className="text-text">{waterPh ?? "—"}</span>
        <span className="text-text-muted">{t("customers.detail.healthCondition")}</span>
        <span className="text-text">
          {healthCondition ? t(`customers.detail.healthConditionLevels.${healthCondition}`) : "—"}
        </span>
        <span className="text-text-muted">{t("customers.detail.familyMembersCount")}</span>
        <span className="text-text">{familyMemberCount}</span>
      </div>
      {measuredReading ? (
        <div className="rounded-xl bg-surface-alt px-3 py-2.5 text-xs text-text-muted">
          <p className="mb-1 font-semibold text-text">{t("customers.detail.latestReadingTitle", { date: formatDate(measuredReading.measuredAt) })}</p>
          <p>
            {t("customers.detail.tdsDialog.measuredTds")}: {measuredReading.tdsPpm ?? "—"} · {t("customers.detail.tdsDialog.measuredPh")}: {measuredReading.ph ?? "—"}
          </p>
        </div>
      ) : null}
    </div>
  )
}
