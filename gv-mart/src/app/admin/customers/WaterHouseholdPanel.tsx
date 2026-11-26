import { useState } from "react"
import { useTranslation } from "react-i18next"
import { zodResolver } from "@hookform/resolvers/zod"
import { useFieldArray, useForm, type UseFormReturn } from "react-hook-form"
import { Loader2, Pencil, Plus, X } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { ChoiceSelect } from "@/components/shared/ChoiceSelect"
import { DatePicker } from "@/components/ui/date-picker"
import { useCustomerWaterFollowup, useSaveWaterHousehold } from "@/hooks/useCustomers"
import {
  MAX_HOUSEHOLD_PROBLEMS,
  WATER_SOURCES,
  cleanHouseholdProblems,
  followUpDateError,
  waterProfileSchema,
  type WaterProfileInput,
} from "@/lib/validation/customer"
import { formatDate } from "@/lib/formatDate"
import { getIstNow } from "@/lib/ist"
import type { WaterProfilePatch } from "@/services/customers"
import type { CustomerMeasuredWaterReading } from "@/services/waterQuality"
import { FIELD_W, NO_SPINNER } from "@/lib/fieldWidth"
import { cn } from "@/lib/utils"
import { WaterHouseholdSummary, type WaterHouseholdValues } from "@/components/shared/WaterHouseholdSummary"

export { waterValuesFromCustomer } from "@/components/shared/WaterHouseholdSummary"

/** Form defaults for a saved profile; an empty problems list still shows one blank row to type into. */
export function waterFormDefaults(v: Partial<WaterHouseholdValues> = {}, followUpDate: string | null = null): WaterProfileInput {
  const problems = v.householdProblems ?? []
  return {
    waterSource: v.waterSource ?? "",
    waterSourceOther: v.waterSourceOther ?? "",
    waterTdsPpm: v.waterTdsPpm ?? undefined,
    waterPh: v.waterPh ?? undefined,
    waterHardnessPpm: v.waterHardnessPpm ?? undefined,
    householdProblems: (problems.length ? problems : [""]).map((value) => ({ value })),
    recommendedSolution: v.waterRecommendedSolution ?? "",
    followUpDate: followUpDate ?? "",
  }
}

/** Any profile field dirty (the follow-up date is the task's, not the profile's). */
export function isWaterProfileDirty(dirtyFields: object): boolean {
  return Object.keys(dirtyFields).some((k) => k !== "followUpDate")
}

/** Past-date guard shared by the form and the panel; sets the field error and returns false when blocked. */
export function checkFollowUpDate(form: UseFormReturn<WaterProfileInput>, savedDate: string | null): boolean {
  const key = followUpDateError(form.getValues("followUpDate"), savedDate, getIstNow().date)
  if (key) form.setError("followUpDate", { message: key })
  return !key
}

const numOrNull = (n: number | undefined) => (n == null || Number.isNaN(n) ? null : n)

/** Parsed form values → the customers patch actually written. */
export function waterFormToPatch(values: WaterProfileInput): WaterProfilePatch {
  const source = values.waterSource || null
  return {
    waterSource: source,
    waterSourceOther: source === "other" ? values.waterSourceOther?.trim() || null : null,
    waterTdsPpm: numOrNull(values.waterTdsPpm),
    waterPh: numOrNull(values.waterPh),
    waterHardnessPpm: numOrNull(values.waterHardnessPpm),
    householdProblems: cleanHouseholdProblems(values.householdProblems),
    waterRecommendedSolution: values.recommendedSolution?.trim() || null,
  }
}

/** True when the form holds nothing worth saving — lets a new customer skip the follow-up write. */
export function isWaterPatchEmpty(p: WaterProfilePatch): boolean {
  return (
    !p.waterSource &&
    p.waterTdsPpm == null &&
    p.waterPh == null &&
    p.waterHardnessPpm == null &&
    !p.householdProblems?.length &&
    !p.waterRecommendedSolution
  )
}

/**
 * The editable fields, shared by the customer form's Water & household step and the detail
 * page's panel so both always show the same inputs.
 */
export function WaterHouseholdFields({ form }: { form: UseFormReturn<WaterProfileInput> }) {
  const { t } = useTranslation()
  const {
    register,
    watch,
    setValue,
    control,
    formState: { errors },
  } = form
  const problems = useFieldArray({ control, name: "householdProblems" })
  const watchedSource = watch("waterSource")
  const numberField = (name: "waterTdsPpm" | "waterPh" | "waterHardnessPpm", label: string, extra: { step: string; max?: number }) => (
    <div className="space-y-1.5">
      <Label htmlFor={name}>{label}</Label>
      <Input id={name} type="number" min={0} inputMode="decimal" className={cn(FIELD_W.reading, NO_SPINNER)} aria-invalid={!!errors[name]} {...extra} {...register(name, { valueAsNumber: true })} />
      {errors[name] ? <p className="text-xs text-danger">{t(errors[name]!.message!)}</p> : null}
    </div>
  )

  return (
    <div className="space-y-3">
      <ChoiceSelect
        id="waterSource"
        className="sm:max-w-xs"
        optional
        label={t("customers.detail.waterSource")}
        value={watchedSource}
        options={WATER_SOURCES.map((s) => ({ value: s, label: t(`customers.detail.waterSourceOptions.${s}`) }))}
        onChange={(v) => setValue("waterSource", v, { shouldValidate: true, shouldDirty: true })}
      />
      {watchedSource === "other" ? (
        <div className="space-y-1.5">
          <Input
            aria-label={t("customers.detail.waterSourceOtherPlaceholder")}
            placeholder={t("customers.detail.waterSourceOtherPlaceholder")}
            {...register("waterSourceOther")}
          />
          {errors.waterSourceOther ? <p className="text-xs text-danger">{t(errors.waterSourceOther.message!)}</p> : null}
        </div>
      ) : null}
      <div className="grid grid-cols-3 gap-2">
        {numberField("waterTdsPpm", t("customers.detail.waterTds"), { step: "1" })}
        {numberField("waterPh", t("customers.detail.waterPh"), { step: "0.1", max: 14 })}
        {numberField("waterHardnessPpm", t("customers.detail.waterHardness"), { step: "1" })}
      </div>
      <fieldset className="space-y-1.5">
        <legend className="mb-1.5 text-sm font-medium text-text">{t("customers.detail.problemsFaced")}</legend>
        {problems.fields.map((field, index) => (
          <div key={field.id} className="space-y-1">
            <div className="flex items-center gap-1.5">
              <Input
                aria-label={`${t("customers.detail.problemsFaced")} ${index + 1}`}
                placeholder={t("customers.detail.problemPlaceholder")}
                maxLength={100}
                {...register(`householdProblems.${index}.value`)}
              />
              <Button
                type="button"
                size="icon"
                variant="ghost"
                aria-label={t("customers.detail.removeProblem")}
                title={t("customers.detail.removeProblem")}
                onClick={() => (problems.fields.length > 1 ? problems.remove(index) : setValue(`householdProblems.${index}.value`, "", { shouldDirty: true }))}
              >
                <X className="size-4" />
              </Button>
            </div>
            {errors.householdProblems?.[index]?.value ? (
              <p className="text-xs text-danger">{t(errors.householdProblems[index]!.value!.message!)}</p>
            ) : null}
          </div>
        ))}
        {problems.fields.length < MAX_HOUSEHOLD_PROBLEMS ? (
          <Button
            type="button"
            size="icon"
            variant="outline"
            aria-label={t("customers.detail.addProblem")}
            title={t("customers.detail.addProblem")}
            onClick={() => problems.append({ value: "" })}
          >
            <Plus className="size-4" />
          </Button>
        ) : null}
      </fieldset>
      <div className="space-y-1.5">
        <Label htmlFor="recommendedSolution">{t("customers.detail.recommendedSolution")}</Label>
        <textarea
          id="recommendedSolution"
          rows={2}
          maxLength={500}
          placeholder={t("customers.detail.recommendedSolutionPlaceholder")}
          aria-invalid={!!errors.recommendedSolution}
          className="w-full resize-none rounded-xl border border-input bg-surface px-3 py-2 text-sm text-text outline-none transition-colors focus-visible:border-ring focus-visible:ring-3 focus-visible:ring-ring/30"
          {...register("recommendedSolution")}
        />
        {errors.recommendedSolution ? <p className="text-xs text-danger">{t(errors.recommendedSolution.message!)}</p> : null}
      </div>
      <div className="space-y-1.5">
        <Label htmlFor="followUpDate">{t("customers.detail.followUpDate")}</Label>
        <div className="flex items-center gap-1.5">
          <DatePicker
            id="followUpDate"
            value={watch("followUpDate") ?? ""}
            min={getIstNow().date}
            aria-invalid={!!errors.followUpDate}
            onChange={(v) => {
              form.clearErrors("followUpDate")
              setValue("followUpDate", v, { shouldDirty: true, shouldValidate: true })
            }}
          />
          {watch("followUpDate") ? (
            <Button
              type="button"
              size="icon"
              variant="ghost"
              aria-label={t("customers.detail.clearFollowUpDate")}
              title={t("customers.detail.clearFollowUpDate")}
              onClick={() => setValue("followUpDate", "", { shouldDirty: true })}
            >
              <X className="size-4" />
            </Button>
          ) : null}
        </div>
        <p className="text-xs text-text-muted">{t("customers.detail.followUpDateHint")}</p>
        {errors.followUpDate ? <p className="text-xs text-danger">{t(errors.followUpDate.message!)}</p> : null}
      </div>
    </div>
  )
}

type WaterHouseholdPanelProps = {
  customerId: string
  values: WaterHouseholdValues
  /** The latest ro_checklists reading from a real service visit (separate, untouched table). */
  measuredReading?: CustomerMeasuredWaterReading | null
  /** master, operation_admin or sales_admin — see canEditWaterHousehold. */
  canEdit: boolean
}

/**
 * Customer detail page's "Water & household" tab: summary with an Edit toggle that saves
 * straight to the customers row. Renders bare (no outer Card), same convention as FamilyMembersPanel.
 */
export function WaterHouseholdPanel({ customerId, values, measuredReading, canEdit }: WaterHouseholdPanelProps) {
  const { t } = useTranslation()
  const [editing, setEditing] = useState(false)
  const save = useSaveWaterHousehold()
  const followup = useCustomerWaterFollowup(canEdit ? customerId : undefined)
  const savedFollowUpDate = followup.data?.dueDate ?? null
  const form = useForm<WaterProfileInput>({ resolver: zodResolver(waterProfileSchema), mode: "onChange", defaultValues: waterFormDefaults(values) })

  const startEditing = () => {
    form.reset(waterFormDefaults(values, savedFollowUpDate))
    setEditing(true)
  }
  const onSave = form.handleSubmit(async (parsed) => {
    if (!checkFollowUpDate(form, savedFollowUpDate)) return
    await save.mutateAsync({
      customerId,
      patch: waterFormToPatch(parsed),
      profileDirty: isWaterProfileDirty(form.formState.dirtyFields),
      followUpDate: parsed.followUpDate || null,
      savedFollowUpDate,
    })
    setEditing(false)
  })

  if (editing) {
    return (
      <form onSubmit={onSave} className="space-y-3">
        <WaterHouseholdFields form={form} />
        {save.isError ? <p className="text-xs text-danger">{(save.error as Error).message}</p> : null}
        <div className="flex justify-end gap-2">
          <Button type="button" size="sm" variant="ghost" onClick={() => setEditing(false)}>
            {t("common.cancel")}
          </Button>
          <Button type="submit" size="sm" disabled={save.isPending}>
            {save.isPending ? <Loader2 className="size-3.5 animate-spin" /> : t("common.save")}
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
          <Button size="sm" variant="outline" onClick={startEditing} disabled={followup.isLoading}>
            <Pencil className="size-3.5" />
            {t("common.edit")}
          </Button>
        ) : null}
      </div>
      <WaterHouseholdSummary values={values} followUpDate={canEdit ? savedFollowUpDate : undefined} />
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
