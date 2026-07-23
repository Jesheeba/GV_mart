import { useTranslation } from "react-i18next"
import { EntityCrudTable, type CrudFieldDef } from "@/components/shared/EntityCrudTable"
import { sparesHooks } from "@/hooks/useMasters"
import type { SpareRow } from "@/services/masters"
import { useProfile } from "@/hooks/useProfile"

export function SparesTab() {
  const { t } = useTranslation()
  const { data: profile } = useProfile()
  const orgId = profile?.org_id

  const { data: rows, isLoading, isError, refetch } = sparesHooks.useList(orgId)
  const createMut = sparesHooks.useCreate()
  const updateMut = sparesHooks.useUpdate()
  const deleteMut = sparesHooks.useDelete()

  const fields: CrudFieldDef[] = [
    { key: "name", label: t("masters.spares.name"), type: "text" },
    { key: "sku", label: t("masters.spares.sku"), type: "text" },
    { key: "price", label: t("masters.spares.price"), type: "number", step: "0.01" },
    { key: "hsn_code", label: t("masters.spares.hsn"), type: "text" },
    // GV.md 1.1: "back wheel 10 min, horn 5 min, tank clean 5 min" — the
    // admin-set standard service time that feeds the SOP checklist (1.1/D4)
    // and the technician's estimated/allowed time (1.2). Blank = not timed
    // yet. operation_admin edits the same column from Inventory (see
    // InventoryTable.tsx) via the narrower set_item_standard_time RPC, since
    // this whole tab is master-only per RLS.
    { key: "standard_time_minutes", label: t("masters.spares.standardTime"), type: "number", step: "1" },
  ]

  return (
    <EntityCrudTable<SpareRow>
      fields={fields}
      rows={rows ?? []}
      getId={(r) => r.id}
      loading={isLoading}
      error={isError ? t("masters.loadFailed") : null}
      onRetry={() => refetch()}
      isMutating={createMut.isPending || updateMut.isPending}
      addLabel={t("masters.spares.add")}
      emptyMessage={t("masters.spares.empty")}
      toFormValues={(r) => ({
        name: r.name,
        sku: r.sku ?? "",
        price: String(r.price),
        hsn_code: r.hsn_code ?? "",
        standard_time_minutes: r.standard_time_minutes != null ? String(r.standard_time_minutes) : "",
      })}
      columns={[
        { key: "name", header: t("masters.spares.name"), render: (r) => <span className="font-medium text-text">{r.name}</span> },
        { key: "sku", header: t("masters.spares.sku"), render: (r) => r.sku || "—" },
        { key: "price", header: t("masters.spares.price"), render: (r) => `₹${r.price}` },
        { key: "hsn", header: t("masters.spares.hsn"), render: (r) => r.hsn_code || "—" },
        {
          key: "standard_time_minutes",
          header: t("masters.spares.standardTime"),
          render: (r) => (r.standard_time_minutes != null ? t("masters.spares.standardTimeValue", { minutes: r.standard_time_minutes }) : "—"),
        },
      ]}
      onCreate={(v) =>
        createMut.mutateAsync({
          org_id: orgId!,
          name: v.name,
          sku: v.sku || null,
          price: Number(v.price) || 0,
          hsn_code: v.hsn_code || null,
          standard_time_minutes: v.standard_time_minutes ? Number(v.standard_time_minutes) : null,
        })
      }
      onUpdate={(id, v) =>
        updateMut.mutateAsync({
          id,
          patch: {
            name: v.name,
            sku: v.sku || null,
            price: Number(v.price) || 0,
            hsn_code: v.hsn_code || null,
            standard_time_minutes: v.standard_time_minutes ? Number(v.standard_time_minutes) : null,
          },
        })
      }
      onDelete={(id) => deleteMut.mutateAsync(id)}
    />
  )
}
