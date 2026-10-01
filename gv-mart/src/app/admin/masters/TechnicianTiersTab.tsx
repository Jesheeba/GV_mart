import { useTranslation } from "react-i18next"
import { Loader2 } from "lucide-react"
import { Button } from "@/components/ui/button"
import { EntityCrudTable, type CrudFieldDef } from "@/components/shared/EntityCrudTable"
import { useProfile } from "@/hooks/useProfile"
import { usePendingPromotions, usePromotionDecision, useTechnicianTierMutations, useTechnicianTiers } from "@/hooks/useTechnicianTiers"
import { formatCurrency } from "@/lib/sale-calc"
import type { TechnicianTierRow } from "@/services/technicianTiers"

function optionalNumber(v: string): number | null {
  return v.trim() === "" ? null : Number(v)
}

function PendingPromotions({ orgId }: { orgId: string | undefined }) {
  const { t } = useTranslation()
  const { data: pending, isLoading } = usePendingPromotions(orgId)
  const { approve, dismiss } = usePromotionDecision()
  const busy = approve.isPending || dismiss.isPending
  const error = (approve.error ?? dismiss.error) as Error | null

  if (isLoading || (pending ?? []).length === 0) return null
  return (
    <div className="rounded-card border border-accent/40 bg-accent-soft p-4">
      <h3 className="mb-2 text-sm font-bold text-text">{t("masters.technicianTiers.pendingTitle")}</h3>
      <ul className="space-y-2">
        {(pending ?? []).map((p) => (
          <li key={p.id} className="flex flex-wrap items-center justify-between gap-2 rounded-md bg-surface p-3">
            <div className="text-sm">
              <span className="font-semibold text-text">{p.technicians?.profiles?.full_name ?? "—"}</span>
              <span className="text-text-muted">
                {" "}
                → {p.technician_tiers?.name ?? "—"} ·{" "}
                {t("masters.technicianTiers.pendingDetail", { amount: formatCurrency(p.earning_snapshot), months: p.window_months })}
              </span>
            </div>
            <div className="flex gap-2">
              <Button size="sm" disabled={busy} onClick={() => approve.mutate(p.id)}>
                {approve.isPending && approve.variables === p.id ? <Loader2 className="size-3.5 animate-spin" /> : null}
                {t("masters.technicianTiers.approve")}
              </Button>
              <Button size="sm" variant="outline" disabled={busy} onClick={() => dismiss.mutate(p.id)}>
                {t("masters.technicianTiers.dismiss")}
              </Button>
            </div>
          </li>
        ))}
      </ul>
      {error ? <p className="mt-2 text-xs text-danger">{error.message}</p> : null}
    </div>
  )
}

export function TechnicianTiersTab() {
  const { t } = useTranslation()
  const { data: profile } = useProfile()
  const orgId = profile?.org_id
  const { data: rows, isLoading, isError, refetch } = useTechnicianTiers(orgId)
  const { create, update, remove } = useTechnicianTierMutations()

  const fields: CrudFieldDef[] = [
    { key: "name", label: t("masters.technicianTiers.name"), type: "text", placeholder: t("masters.technicianTiers.namePlaceholder"), required: true },
    { key: "rank", label: t("masters.technicianTiers.rank"), type: "number", step: "1", min: 1, required: true },
    { key: "monthly_salary", label: t("masters.technicianTiers.monthlySalary"), type: "number", step: "0.01", min: 0, required: true },
    { key: "required_earning", label: t("masters.technicianTiers.requiredEarning"), type: "number", step: "0.01", min: 0 },
    { key: "required_months", label: t("masters.technicianTiers.requiredMonths"), type: "number", step: "1", min: 1 },
  ]

  return (
    <div className="space-y-4">
      <PendingPromotions orgId={orgId} />
      <p className="text-xs text-text-muted">{t("masters.technicianTiers.hint")}</p>

      {!isLoading && !isError && (rows ?? []).length > 0 ? (
        <div className="flex gap-3 overflow-x-auto pb-1">
          {(rows ?? []).map((r, i) => (
            <div
              key={r.id}
              className={`flex min-w-56 flex-1 flex-col gap-3 rounded-card p-5 text-white ${
                i % 2 === 0 ? "bg-ink" : "bg-[color-mix(in_srgb,var(--accent)_70%,var(--ink)_30%)]"
              }`}
            >
              <span className="text-base font-semibold">
                {r.name} <span className="text-xs font-normal text-white/70">#{r.rank}</span>
              </span>
              <div>
                <div className="text-xs text-white/70">{t("masters.technicianTiers.monthlySalary")}</div>
                <div className="text-2xl font-bold tabular-nums">{formatCurrency(r.monthly_salary)}</div>
              </div>
              <div className="text-xs text-white/70">
                {r.required_earning != null && r.required_months != null
                  ? t("masters.technicianTiers.requirement", { amount: formatCurrency(r.required_earning), months: r.required_months })
                  : t("masters.technicianTiers.noRequirement")}
              </div>
            </div>
          ))}
        </div>
      ) : null}

      <EntityCrudTable<TechnicianTierRow>
        fields={fields}
        rows={rows ?? []}
        getId={(r) => r.id}
        loading={isLoading}
        error={isError ? t("masters.loadFailed") : null}
        onRetry={() => refetch()}
        isMutating={create.isPending || update.isPending}
        addLabel={t("masters.technicianTiers.add")}
        emptyMessage={t("masters.technicianTiers.empty")}
        toFormValues={(r) => ({
          name: r.name,
          rank: String(r.rank),
          monthly_salary: String(r.monthly_salary),
          required_earning: r.required_earning == null ? "" : String(r.required_earning),
          required_months: r.required_months == null ? "" : String(r.required_months),
        })}
        columns={[
          { key: "rank", header: t("masters.technicianTiers.rank"), render: (r) => r.rank },
          { key: "name", header: t("masters.technicianTiers.name"), render: (r) => <span className="font-medium text-text">{r.name}</span> },
          { key: "salary", header: t("masters.technicianTiers.monthlySalary"), render: (r) => formatCurrency(r.monthly_salary) },
          { key: "earning", header: t("masters.technicianTiers.requiredEarning"), render: (r) => (r.required_earning == null ? "—" : formatCurrency(r.required_earning)) },
          { key: "months", header: t("masters.technicianTiers.requiredMonths"), render: (r) => r.required_months ?? "—" },
        ]}
        onCreate={(v) =>
          create.mutateAsync({
            org_id: orgId!,
            name: v.name,
            rank: Number(v.rank),
            monthly_salary: Number(v.monthly_salary) || 0,
            required_earning: optionalNumber(v.required_earning),
            required_months: optionalNumber(v.required_months),
          })
        }
        onUpdate={(id, v) =>
          update.mutateAsync({
            id,
            patch: {
              name: v.name,
              rank: Number(v.rank),
              monthly_salary: Number(v.monthly_salary) || 0,
              required_earning: optionalNumber(v.required_earning),
              required_months: optionalNumber(v.required_months),
            },
          })
        }
        onDelete={(id) => remove.mutateAsync(id)}
      />
    </div>
  )
}
