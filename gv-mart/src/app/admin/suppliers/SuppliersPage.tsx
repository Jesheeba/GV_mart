import { useMemo, useState } from "react"
import { useTranslation } from "react-i18next"
import { ListChecks, Search } from "lucide-react"
import { Button } from "@/components/ui/button"
import { EntityCrudTable, type CrudFieldDef } from "@/components/shared/EntityCrudTable"
import { useCreateSupplier, useDeleteSupplier, useSuppliersList, useUpdateSupplier } from "@/hooks/useSuppliers"
import { supplierHasPurchaseHistory, type SupplierRow } from "@/services/suppliers"
import { normalizeInMobile } from "@/lib/purchase"
import { useProfile } from "@/hooks/useProfile"
import { SupplierItemsPanel } from "./SupplierItemsPanel"

export function SuppliersPage() {
  const { t } = useTranslation()
  const { data: profile } = useProfile()
  const orgId = profile?.org_id

  const { data: allRows, isLoading, isError, refetch } = useSuppliersList(orgId)
  const createMut = useCreateSupplier()
  const updateMut = useUpdateSupplier()
  const deleteMut = useDeleteSupplier()

  const [selectedId, setSelectedId] = useState<string | null>(null)
  const [search, setSearch] = useState("")
  const searchTerm = search.trim().toLowerCase()
  const rows = useMemo(
    () => (allRows ?? []).filter((r) => !searchTerm || r.name.toLowerCase().includes(searchTerm) || (r.contact ?? "").includes(searchTerm)),
    [allRows, searchTerm]
  )
  const selected = (allRows ?? []).find((r) => r.id === selectedId) ?? null

  const fields: CrudFieldDef[] = [
    { key: "name", label: t("suppliers.name"), type: "text", required: true },
    { key: "contact", label: t("suppliers.contact"), type: "tel", pattern: "[0-9+\\-\\s]{7,15}", patternMessage: t("masters.errors.phoneInvalid") },
    // 10-digit mobile, optional +91 / 0 prefix, spaces or dashes allowed; the DB sends to the last 10 digits
    { key: "whatsapp", label: t("suppliers.whatsapp"), type: "tel", pattern: "(\\+?91|0)?[\\s\\-]*[6-9]([\\s\\-]*[0-9]){9}", patternMessage: t("suppliers.whatsappInvalid") },
    { key: "rating", label: t("suppliers.rating"), type: "number", step: "0.1", min: 0, max: 5 },
    { key: "credit_days", label: t("suppliers.creditDays"), type: "number", step: "1", min: 0 },
    {
      key: "is_active",
      label: t("suppliers.status"),
      type: "select",
      options: [
        { value: "true", label: t("suppliers.active") },
        { value: "false", label: t("suppliers.inactive") },
      ],
    },
  ]

  const formatCreditTerms = (days: number) => (days === 0 ? t("suppliers.creditImmediate") : t("suppliers.creditNetDays", { days }))

  return (
    <div className="space-y-4 pt-2">
      <div className="flex flex-wrap items-end justify-between gap-3">
        <div>
          <h1 className="text-2xl font-bold text-text">{t("nav.suppliers")}</h1>
          <p className="text-sm text-text-muted">{t("suppliers.subtitle")}</p>
        </div>
        <div className="flex w-64 items-center gap-2.25 rounded-full border border-border bg-surface-alt px-3.5 py-2">
          <Search className="size-3.75 shrink-0 text-text-muted" />
          <input
            type="text"
            value={search}
            onChange={(e) => setSearch(e.target.value)}
            placeholder={t("suppliers.search")}
            className="w-full bg-transparent text-xs font-medium text-text outline-none placeholder:text-text-muted"
          />
        </div>
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
          credit_days: String(r.credit_days ?? 0),
          is_active: String(r.is_active),
        })}
        columns={[
          { key: "name", header: t("suppliers.name"), render: (r) => <span className="font-medium text-text">{r.name}</span> },
          { key: "contact", header: t("suppliers.contact"), render: (r) => r.contact || "—" },
          {
            key: "whatsapp",
            header: t("suppliers.whatsapp"),
            render: (r) =>
              normalizeInMobile(r.whatsapp) ? r.whatsapp : <span className="text-xs font-medium text-danger">{t("suppliers.noWhatsapp")}</span>,
          },
          { key: "rating", header: t("suppliers.rating"), render: (r) => (r.rating != null ? `★ ${r.rating}` : "—") },
          { key: "creditDays", header: t("suppliers.creditDays"), render: (r) => formatCreditTerms(r.credit_days ?? 0) },
          {
            key: "status",
            header: t("suppliers.status"),
            render: (r) => <span className={r.is_active ? "text-success" : "text-text-muted"}>{t(r.is_active ? "suppliers.active" : "suppliers.inactive")}</span>,
          },
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
          createMut.mutateAsync({
            org_id: orgId!,
            name: v.name,
            contact: v.contact || null,
            whatsapp: v.whatsapp || null,
            rating: v.rating ? Number(v.rating) : null,
            credit_days: v.credit_days ? Number(v.credit_days) : 0,
            is_active: v.is_active !== "false",
          })
        }
        onUpdate={(id, v) =>
          updateMut.mutateAsync({
            id,
            patch: {
              name: v.name,
              contact: v.contact || null,
              whatsapp: v.whatsapp || null,
              rating: v.rating ? Number(v.rating) : null,
              credit_days: v.credit_days ? Number(v.credit_days) : 0,
              is_active: v.is_active !== "false",
            },
          })
        }
        onDelete={(id) => deleteMut.mutateAsync(id)}
        checkCanDelete={async (id) => !(await supplierHasPurchaseHistory(id))}
        cannotDeleteMessage={t("suppliers.cannotDelete")}
      />

      {selected ? <SupplierItemsPanel supplier={selected} /> : null}
    </div>
  )
}
