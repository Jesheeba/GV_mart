import { useTranslation } from "react-i18next"
import { EntityCrudTable, type CrudFieldDef } from "@/components/shared/EntityCrudTable"
import { rentalPlansHooks } from "@/hooks/useMasters"
import type { RentalPlanRow } from "@/services/masters"
import { useProfile } from "@/hooks/useProfile"

/** inclusions is jsonb — represented in the form as a comma-separated list,
 * same convention AmcPlansTab already uses. */
function inclusionsToText(inclusions: unknown): string {
  return Array.isArray(inclusions) ? inclusions.filter((x) => typeof x === "string").join(", ") : ""
}
function textToInclusions(text: string): string[] {
  return text
    .split(",")
    .map((s) => s.trim())
    .filter(Boolean)
}

export function RentalPlansTab() {
  const { t } = useTranslation()
  const { data: profile } = useProfile()
  const orgId = profile?.org_id

  const { data: rows, isLoading, isError, refetch } = rentalPlansHooks.useList(orgId)
  const createMut = rentalPlansHooks.useCreate()
  const updateMut = rentalPlansHooks.useUpdate()
  const deleteMut = rentalPlansHooks.useDelete()

  const fields: CrudFieldDef[] = [
    { key: "name", label: t("masters.rentalPlans.name"), type: "text", placeholder: t("masters.rentalPlans.namePlaceholder"), required: true },
    { key: "monthly_rate", label: t("masters.rentalPlans.monthlyRate"), type: "number", step: "0.01", min: 0, required: true },
    { key: "visits_per_year", label: t("masters.rentalPlans.visitsPerYear"), type: "number", step: "1", required: true, min: 1 },
    { key: "inclusions", label: t("masters.rentalPlans.inclusions"), type: "text", placeholder: t("masters.rentalPlans.inclusionsPlaceholder") },
  ]

  return (
    <div className="space-y-4">
      {!isLoading && !isError && (rows ?? []).length > 0 ? (
        <div className="flex gap-3 overflow-x-auto pb-1">
          {(rows ?? []).map((r, i) => (
            <div
              key={r.id}
              className={`flex min-w-56 flex-1 flex-col gap-3 rounded-card p-5 text-white ${
                i % 2 === 0 ? "bg-ink" : "bg-[color-mix(in_srgb,var(--accent)_70%,var(--ink)_30%)]"
              }`}
            >
              <span className="text-base font-semibold">{r.name}</span>
              <div>
                <div className="text-xs text-white/70">{t("masters.rentalPlans.monthlyRate")}</div>
                <div className="text-2xl font-bold tabular-nums">₹{r.monthly_rate}/mo</div>
              </div>
              <div className="text-xs text-white/70">
                {t("masters.rentalPlans.visitsPerYear")}: {r.visits_per_year}
              </div>
            </div>
          ))}
        </div>
      ) : null}

      <EntityCrudTable<RentalPlanRow>
        fields={fields}
        rows={rows ?? []}
        getId={(r) => r.id}
        loading={isLoading}
        error={isError ? t("masters.loadFailed") : null}
        onRetry={() => refetch()}
        isMutating={createMut.isPending || updateMut.isPending}
        addLabel={t("masters.rentalPlans.add")}
        emptyMessage={t("masters.rentalPlans.empty")}
        toFormValues={(r) => ({
          name: r.name,
          monthly_rate: String(r.monthly_rate),
          visits_per_year: String(r.visits_per_year),
          inclusions: inclusionsToText(r.inclusions),
        })}
        columns={[
          { key: "name", header: t("masters.rentalPlans.name"), render: (r) => <span className="font-medium text-text">{r.name}</span> },
          { key: "monthlyRate", header: t("masters.rentalPlans.monthlyRate"), render: (r) => `₹${r.monthly_rate}/mo` },
          { key: "visits", header: t("masters.rentalPlans.visitsPerYear"), render: (r) => r.visits_per_year },
        ]}
        onCreate={(v) =>
          createMut.mutateAsync({
            org_id: orgId!,
            name: v.name,
            monthly_rate: Number(v.monthly_rate) || 0,
            visits_per_year: Number(v.visits_per_year) || 4,
            inclusions: textToInclusions(v.inclusions),
          })
        }
        onUpdate={(id, v) =>
          updateMut.mutateAsync({
            id,
            patch: {
              name: v.name,
              monthly_rate: Number(v.monthly_rate) || 0,
              visits_per_year: Number(v.visits_per_year) || 4,
              inclusions: textToInclusions(v.inclusions),
            },
          })
        }
        onDelete={(id) => deleteMut.mutateAsync(id)}
      />
    </div>
  )
}
