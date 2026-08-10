import { useState } from "react"
import { useTranslation } from "react-i18next"
import { Wrench } from "lucide-react"
import { Button } from "@/components/ui/button"
import { EntityCrudTable, type CrudFieldDef } from "@/components/shared/EntityCrudTable"
import { complaintTypesHooks } from "@/hooks/useMasters"
import type { ComplaintTypeRow } from "@/services/masters"
import { useProfile } from "@/hooks/useProfile"
import { ComplaintTypeSparesPanel } from "./ComplaintTypeSparesPanel"

const CATEGORIES = ["ro", "ac", "inverter", "battery"] as const

/**
 * Meeting spec E1: complaint-name master, tagged to a product category,
 * feeding the filtered auto-suggest on the customer booking and admin
 * new-complaint screens. Previously declined, now authorized (Build Order
 * STEP 6.4).
 *
 * Schema now also carries a nullable `product_id` (migration
 * 20260729140000_complaint_types_per_product.sql): rows with product_id
 * null are the category-wide defaults this tab manages; product-specific
 * overrides are managed from Inventory / Masters > Products instead. This
 * tab filters the shared list down to product_id === null and always
 * writes null on create so it never creates or edits a product-scoped row.
 */
export function ComplaintTypesTab() {
  const { t } = useTranslation()
  const { data: profile } = useProfile()
  const orgId = profile?.org_id

  const { data: allRows, isLoading, isError, refetch } = complaintTypesHooks.useList(orgId)
  const rows = (allRows ?? []).filter((r) => r.product_id === null)
  const createMut = complaintTypesHooks.useCreate()
  const updateMut = complaintTypesHooks.useUpdate()
  const deleteMut = complaintTypesHooks.useDelete()

  // Issue-based spare suggestions (2026-08-06) — complaint_type<->spares
  // connector (see ComplaintTypeSparesPanel.tsx), same per-row-action
  // pattern as ProductsTab.tsx's spares/complaints columns.
  const [sparesComplaintTypeId, setSparesComplaintTypeId] = useState<string | null>(null)
  const sparesComplaintType = rows.find((r) => r.id === sparesComplaintTypeId)

  const fields: CrudFieldDef[] = [
    {
      key: "product_category",
      label: t("masters.complaintTypes.category"),
      type: "select",
      options: CATEGORIES.map((c) => ({ value: c, label: t(`masters.categories.${c}`) })),
    },
    { key: "label", label: t("masters.complaintTypes.label"), type: "text", placeholder: t("masters.complaintTypes.labelPlaceholder"), required: true },
  ]

  return (
    <div className="space-y-3">
      <p className="px-1 text-xs text-text-muted">{t("masters.complaintTypes.hint")}</p>
      <EntityCrudTable<ComplaintTypeRow>
        fields={fields}
        rows={rows}
        getId={(r) => r.id}
        loading={isLoading}
        error={isError ? t("masters.loadFailed") : null}
        onRetry={() => refetch()}
        isMutating={createMut.isPending || updateMut.isPending}
        addLabel={t("masters.complaintTypes.add")}
        emptyMessage={t("masters.complaintTypes.empty")}
        toFormValues={(r) => ({ product_category: r.product_category, label: r.label })}
        columns={[
          { key: "category", header: t("masters.complaintTypes.category"), render: (r) => t(`masters.categories.${r.product_category}`) },
          { key: "label", header: t("masters.complaintTypes.label"), render: (r) => <span className="font-medium text-text">{r.label}</span> },
          {
            key: "spares",
            header: "",
            className: "text-right",
            render: (r) => (
              <Button size="icon-xs" variant="ghost" title={t("masters.complaintTypeSpares.manage")} onClick={() => setSparesComplaintTypeId(r.id)}>
                <Wrench className="size-3.5" />
              </Button>
            ),
          },
        ]}
        onCreate={(v) =>
          createMut.mutateAsync({
            org_id: orgId!,
            product_category: v.product_category as ComplaintTypeRow["product_category"],
            label: v.label,
            product_id: null,
          })
        }
        onUpdate={(id, v) =>
          updateMut.mutateAsync({
            id,
            patch: { product_category: v.product_category as ComplaintTypeRow["product_category"], label: v.label },
          })
        }
        onDelete={(id) => deleteMut.mutateAsync(id)}
      />

      {sparesComplaintType ? (
        <ComplaintTypeSparesPanel
          key={sparesComplaintType.id}
          orgId={orgId}
          complaintTypeId={sparesComplaintType.id}
          complaintTypeLabel={sparesComplaintType.label}
          onClose={() => setSparesComplaintTypeId(null)}
        />
      ) : null}
    </div>
  )
}
