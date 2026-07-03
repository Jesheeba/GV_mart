import { useState } from "react"
import { useTranslation } from "react-i18next"
import { ListChecks } from "lucide-react"
import { Button } from "@/components/ui/button"
import { EntityCrudTable, type CrudFieldDef } from "@/components/shared/EntityCrudTable"
import { useCreateSupplier, useDeleteSupplier, useSuppliersList, useUpdateSupplier } from "@/hooks/useSuppliers"
import type { SupplierRow } from "@/services/suppliers"
import { useProfile } from "@/hooks/useProfile"
import { SupplierItemsPanel } from "./SupplierItemsPanel"

export function SuppliersPage() {
  const { t } = useTranslation()
  const { data: profile } = useProfile()
  const orgId = profile?.org_id

  const { data: rows, isLoading, isError, refetch } = useSuppliersList(orgId)
  const createMut = useCreateSupplier()
  const updateMut = useUpdateSupplier()
  const deleteMut = useDeleteSupplier()

  const [selectedId, setSelectedId] = useState<string | null>(null)
  const selected = (rows ?? []).find((r) => r.id === selectedId) ?? null

  const fields: CrudFieldDef[] = [
    { key: "name", label: t("suppliers.name"), type: "text" },
    { key: "contact", label: t("suppliers.contact"), type: "text" },
    { key: "whatsapp", label: t("suppliers.whatsapp"), type: "text" },
    { key: "rating", label: t("suppliers.rating"), type: "number", step: "0.1" },
  ]

  return (
    <div className="space-y-4 pt-2">
      <div>
        <h1 className="text-2xl font-bold text-text">{t("nav.suppliers")}</h1>
        <p className="text-sm text-text-muted">{t("suppliers.subtitle")}</p>
      </div>

      <EntityCrudTable<SupplierRow>
        fields={fields}
        rows={rows ?? []}
        getId={(r) => r.id}
        loading={isLoading}
        error={isError ? t("suppliers.loadFailed") : null}
        onRetry={() => refetch()}
        isMutating={createMut.isPending || updateMut.isPending}
        addLabel={t("suppliers.add")}
        emptyMessage={t("suppliers.empty")}
        toFormValues={(r) => ({
          name: r.name,
          contact: r.contact ?? "",
          whatsapp: r.whatsapp ?? "",
          rating: r.rating != null ? String(r.rating) : "",
        })}
        columns={[
          { key: "name", header: t("suppliers.name"), render: (r) => <span className="font-medium text-text">{r.name}</span> },
          { key: "contact", header: t("suppliers.contact"), render: (r) => r.contact || "—" },
          { key: "whatsapp", header: t("suppliers.whatsapp"), render: (r) => r.whatsapp || "—" },
          { key: "rating", header: t("suppliers.rating"), render: (r) => (r.rating != null ? `★ ${r.rating}` : "—") },
          {
            key: "manage",
            header: "",
            render: (r) => (
              <Button size="sm" variant="outline" onClick={() => setSelectedId(r.id)}>
                <ListChecks className="size-3.5" />
                {t("suppliers.manageItems")}
              </Button>
            ),
          },
        ]}
        onCreate={(v) =>
          createMut.mutate({
            org_id: orgId!,
            name: v.name,
            contact: v.contact || null,
            whatsapp: v.whatsapp || null,
            rating: v.rating ? Number(v.rating) : null,
          })
        }
        onUpdate={(id, v) =>
          updateMut.mutate({
            id,
            patch: { name: v.name, contact: v.contact || null, whatsapp: v.whatsapp || null, rating: v.rating ? Number(v.rating) : null },
          })
        }
        onDelete={(id) => deleteMut.mutate(id)}
      />

      {selected ? <SupplierItemsPanel supplier={selected} /> : null}
    </div>
  )
}
