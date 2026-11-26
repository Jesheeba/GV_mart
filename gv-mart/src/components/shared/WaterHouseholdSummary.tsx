import { useTranslation } from "react-i18next"
import type { Enums } from "@/types/database"
import { formatDate } from "@/lib/formatDate"

/** The saved water & household values, as read from the customers row. */
export type WaterHouseholdValues = {
  waterSource: Enums<"water_source_type"> | null
  waterSourceOther: string | null
  waterTdsPpm: number | null
  waterPh: number | null
  waterHardnessPpm: number | null
  householdProblems: string[] | null
  waterRecommendedSolution: string | null
}

/** Pulls the water & household values off a customers row (columns may be absent before the migration lands). */
export function waterValuesFromCustomer(c: {
  water_source?: WaterHouseholdValues["waterSource"]
  water_source_other?: string | null
  water_tds_ppm?: number | null
  water_ph?: number | null
  water_hardness_ppm?: number | null
  household_problems?: string[] | null
  water_recommended_solution?: string | null
}): WaterHouseholdValues {
  return {
    waterSource: c.water_source ?? null,
    waterSourceOther: c.water_source_other ?? null,
    waterTdsPpm: c.water_tds_ppm ?? null,
    waterPh: c.water_ph ?? null,
    waterHardnessPpm: c.water_hardness_ppm ?? null,
    householdProblems: c.household_problems ?? null,
    waterRecommendedSolution: c.water_recommended_solution ?? null,
  }
}

/** Read-only rows, shared by the admin panel, the technician job/history pages and the customer app. */
/** `followUpDate` is staff-only (passed by the admin panel); undefined hides the row. */
export function WaterHouseholdSummary({ values, followUpDate }: { values: WaterHouseholdValues; followUpDate?: string | null }) {
  const { t } = useTranslation()
  const problems = values.householdProblems ?? []
  return (
    <div className="grid grid-cols-2 gap-y-2 px-1 text-sm">
      <span className="text-text-muted">{t("customers.detail.waterSource")}</span>
      <span className="text-text">
        {values.waterSource
          ? values.waterSource === "other" && values.waterSourceOther
            ? values.waterSourceOther
            : t(`customers.detail.waterSourceOptions.${values.waterSource}`)
          : "—"}
      </span>
      <span className="text-text-muted">{t("customers.detail.waterTds")}</span>
      <span className="text-text">{values.waterTdsPpm ?? "—"}</span>
      <span className="text-text-muted">{t("customers.detail.waterPh")}</span>
      <span className="text-text">{values.waterPh ?? "—"}</span>
      <span className="text-text-muted">{t("customers.detail.waterHardness")}</span>
      <span className="text-text">{values.waterHardnessPpm ?? "—"}</span>
      <span className="text-text-muted">{t("customers.detail.problemsFaced")}</span>
      {problems.length ? (
        <ul className="list-disc space-y-0.5 pl-4 text-text">
          {problems.map((p) => (
            <li key={p}>{p}</li>
          ))}
        </ul>
      ) : (
        <span className="text-text">—</span>
      )}
      <span className="text-text-muted">{t("customers.detail.recommendedSolution")}</span>
      <span className="whitespace-pre-line text-text">{values.waterRecommendedSolution || "—"}</span>
      {followUpDate !== undefined ? (
        <>
          <span className="text-text-muted">{t("customers.detail.followUpDate")}</span>
          <span className="text-text">{followUpDate ? formatDate(followUpDate) : "—"}</span>
        </>
      ) : null}
    </div>
  )
}

