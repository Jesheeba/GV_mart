import { useMemo, useState } from "react"
import { useTranslation } from "react-i18next"
import { ClipboardList, Wrench } from "lucide-react"
import { Button } from "@/components/ui/button"
import { EntityCrudTable, type CrudFieldDef } from "@/components/shared/EntityCrudTable"
import { brandsHooks, modelsHooks, productsHooks } from "@/hooks/useMasters"
import { useProfile } from "@/hooks/useProfile"
import type { Enums } from "@/types/database"
import { ProductComplaintsPanel } from "./ProductComplaintsPanel"
import { ProductSparesPanel } from "./ProductSparesPanel"

const CATEGORIES = ["ro", "ac", "inverter", "battery"] as const satisfies readonly Enums<"brand_category">[]

type ProductWithRefs = {
  id: string
  org_id: string
  brand_id: string
  model_id: string
  name: string
  category: Enums<"brand_category">
  price: number
  cost_price: number | null
  hsn_code: string | null
  warranty_months: number
  // GV.md 1.1 — same admin-set standard time as spares (SparesTab.tsx).
  standard_time_minutes: number | null
  // Task 6 (2026-07-30) — enable/disable, see
  // 20260730170000_product_spare_mapping_and_active_flags.sql.
  is_active: boolean
  created_at: string
  updated_at: string
  brands: { name: string } | null
  models: { name: string } | null
}

export function ProductsTab() {
  const { t } = useTranslation()
  const { data: profile } = useProfile()
  const orgId = profile?.org_id

  const { data: brands } = brandsHooks.useList(orgId)
  const { data: models } = modelsHooks.useList(orgId)
  const { data: rows, isLoading, isError, refetch } = productsHooks.useList(orgId)
  const createMut = productsHooks.useCreate()
  const updateMut = productsHooks.useUpdate()
  const deleteMut = productsHooks.useDelete()

  // Admin-side product↔complaints connector (see ProductComplaintsPanel.tsx)
  // — opened per-row via the ClipboardList action column below.
  const [complaintsProductId, setComplaintsProductId] = useState<string | null>(null)
  const complaintsProduct = (rows ?? []).find((r) => r.id === complaintsProductId) as ProductWithRefs | undefined

  // Task 6 — product↔spares connector (see ProductSparesPanel.tsx), same
  // per-row-action pattern as complaints above.
  const [sparesProductId, setSparesProductId] = useState<string | null>(null)
  const sparesProduct = (rows ?? []).find((r) => r.id === sparesProductId) as ProductWithRefs | undefined

  const brandOptions = useMemo(() => (brands ?? []).map((b) => ({ value: b.id, label: b.name })), [brands])
  const modelOptions = useMemo(
    () =>
      (models ?? []).map((m) => ({
        value: m.id,
        label: `${m.name} (${(m as { brands: { name: string } | null }).brands?.name ?? "—"})`,
      })),
    [models]
  )

  const fields: CrudFieldDef[] = [
    { key: "name", label: t("masters.products.name"), type: "text", required: true },
    { key: "brand_id", label: t("masters.products.brand"), type: "select", options: brandOptions },
    { key: "model_id", label: t("masters.products.model"), type: "select", options: modelOptions },
    {
      key: "category",
      label: t("masters.products.category"),
      type: "select",
      options: CATEGORIES.map((c) => ({ value: c, label: t(`masters.categories.${c}`) })),
    },
    { key: "price", label: t("masters.products.price"), type: "number", step: "0.01", required: true, min: 0 },
    { key: "cost_price", label: t("masters.products.costPrice"), type: "number", step: "0.01", placeholder: t("masters.costPriceNotSet"), min: 0 },
    { key: "hsn_code", label: t("masters.products.hsn"), type: "text", pattern: "\\d{4,8}", patternMessage: t("masters.errors.hsnInvalid") },
    { key: "warranty_months", label: t("masters.products.warrantyMonths"), type: "number", step: "1", min: 0 },
    { key: "standard_time_minutes", label: t("masters.products.standardTime"), type: "number", step: "1", min: 0 },
  ]

  if (!brands?.length || !models?.length) {
    return <p className="px-1 text-sm text-text-muted">{t("masters.products.needsBrandModelFirst")}</p>
  }

  return (
    <>
      <EntityCrudTable<ProductWithRefs>
        fields={fields}
        rows={(rows ?? []) as ProductWithRefs[]}
        getId={(r) => r.id}
        loading={isLoading}
        error={isError ? t("masters.loadFailed") : null}
        onRetry={() => refetch()}
        isMutating={createMut.isPending || updateMut.isPending}
        addLabel={t("masters.products.add")}
        emptyMessage={t("masters.products.empty")}
        toFormValues={(r) => ({
          name: r.name,
          brand_id: r.brand_id,
          model_id: r.model_id,
          category: r.category,
          price: String(r.price),
          cost_price: r.cost_price != null ? String(r.cost_price) : "",
          hsn_code: r.hsn_code ?? "",
          warranty_months: String(r.warranty_months),
          standard_time_minutes: r.standard_time_minutes != null ? String(r.standard_time_minutes) : "",
        })}
        columns={[
          { key: "name", header: t("masters.products.name"), render: (r) => <span className="font-medium text-text">{r.name}</span> },
          { key: "brand", header: t("masters.products.brand"), render: (r) => r.brands?.name ?? "—" },
          { key: "model", header: t("masters.products.model"), render: (r) => r.models?.name ?? "—" },
          { key: "price", header: t("masters.products.price"), render: (r) => `₹${r.price}` },
          { key: "cost_price", header: t("masters.products.costPrice"), render: (r) => (r.cost_price != null ? `₹${r.cost_price}` : t("masters.costPriceNotSet")) },
          { key: "warranty", header: t("masters.products.warrantyMonths"), render: (r) => r.warranty_months },
          {
            key: "standard_time_minutes",
            header: t("masters.products.standardTime"),
            render: (r) => (r.standard_time_minutes != null ? t("masters.spares.standardTimeValue", { minutes: r.standard_time_minutes }) : "—"),
          },
          {
            key: "is_active",
            header: t("masters.products.status"),
            render: (r) => (
              <button
                type="button"
                disabled={updateMut.isPending}
                onClick={() => updateMut.mutate({ id: r.id, patch: { is_active: !r.is_active } })}
                className={`rounded-full px-2 py-0.5 text-xs font-semibold ${
                  r.is_active ? "bg-success/10 text-success" : "bg-danger/10 text-danger"
                }`}
              >
                {r.is_active ? t("masters.active") : t("masters.inactive")}
              </button>
            ),
          },
          {
            key: "spares",
            header: "",
            className: "text-right",
            render: (r) => (
              <Button size="icon-xs" variant="ghost" title={t("masters.productSpares.manage")} onClick={() => setSparesProductId(r.id)}>
                <Wrench className="size-3.5" />
              </Button>
            ),
          },
          {
            key: "complaints",
            header: "",
            className: "text-right",
            render: (r) => (
              <Button
                size="icon-xs"
                variant="ghost"
                title={t("masters.productComplaints.manage")}
                onClick={() => setComplaintsProductId(r.id)}
              >
                <ClipboardList className="size-3.5" />
              </Button>
            ),
          },
        ]}
        onCreate={(v) =>
          createMut.mutateAsync({
            org_id: orgId!,
            name: v.name,
            brand_id: v.brand_id,
            model_id: v.model_id,
            category: v.category as Enums<"brand_category">,
            price: Number(v.price) || 0,
            cost_price: v.cost_price ? Number(v.cost_price) : null,
            hsn_code: v.hsn_code || null,
            warranty_months: Number(v.warranty_months) || 12,
            standard_time_minutes: v.standard_time_minutes ? Number(v.standard_time_minutes) : null,
          })
        }
        onUpdate={(id, v) =>
          updateMut.mutateAsync({
            id,
            patch: {
              name: v.name,
              brand_id: v.brand_id,
              model_id: v.model_id,
              category: v.category as Enums<"brand_category">,
              price: Number(v.price) || 0,
              cost_price: v.cost_price ? Number(v.cost_price) : null,
              hsn_code: v.hsn_code || null,
              warranty_months: Number(v.warranty_months) || 12,
              standard_time_minutes: v.standard_time_minutes ? Number(v.standard_time_minutes) : null,
            },
          })
        }
        onDelete={(id) => deleteMut.mutateAsync(id)}
      />

      {complaintsProduct ? (
        <ProductComplaintsPanel
          key={complaintsProduct.id}
          orgId={orgId}
          productId={complaintsProduct.id}
          productCategory={complaintsProduct.category}
          productName={complaintsProduct.name}
          onClose={() => setComplaintsProductId(null)}
        />
      ) : null}

      {sparesProduct ? (
        <ProductSparesPanel
          key={sparesProduct.id}
          orgId={orgId}
          productId={sparesProduct.id}
          productName={sparesProduct.name}
          onClose={() => setSparesProductId(null)}
        />
      ) : null}
    </>
  )
}
