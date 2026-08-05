import { useTranslation } from "react-i18next"
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card"
import { EntityCrudTable, type CrudFieldDef } from "@/components/shared/EntityCrudTable"
import { ReorderableListCard } from "@/components/shared/ReorderableListCard"
import {
  productAttributeKeysHooks,
  productEnquiryComparisonFieldsHooks,
  productEnquiryCtaConfigHooks,
  productEnquiryFiltersHooks,
  productEnquiryTabsHooks,
} from "@/hooks/useMasters"
import { useProfile } from "@/hooks/useProfile"
import type { Enums, Json, Tables } from "@/types/database"

const TAB_TYPES: Enums<"product_enquiry_tab_type">[] = ["catalog_grid", "video_library"]
const CTA_TYPES: Enums<"product_enquiry_cta_type">[] = ["quotation", "callback", "share"]
const PRODUCT_FIELDS: Enums<"product_enquiry_field">[] = ["category", "brand", "price_range"]
const TOPICS: Enums<"enquiry_type">[] = ["online", "price", "quality", "customization", "water_premium", "budget"]

function toStringArray(json: Json | null | undefined): string[] {
  return Array.isArray(json) ? json.filter((x): x is string => typeof x === "string") : []
}

/**
 * Product Enquiry rebuild (2026-08-04), Phase 2 — admin config screen for
 * the customer Product Enquiry module layer. Reachable from Masters as its
 * own tile (see MastersPage.tsx). EMI settings live on SettingsTab.tsx
 * instead (it's a settings row field, not its own list).
 */
export function ProductEnquiryConfigTab() {
  const { t } = useTranslation()
  const { data: profile } = useProfile()
  const orgId = profile?.org_id
  const { data: attributeKeys } = productAttributeKeysHooks.useList(orgId)
  const activeAttributeKeys = (attributeKeys ?? []).filter((k) => k.is_active)

  return (
    <div className="space-y-4">
      <Card>
        <CardHeader>
          <CardTitle>{t("masters.productEnquiryConfig.tabsTitle")}</CardTitle>
        </CardHeader>
        <CardContent>
          <TabsSection orgId={orgId} />
        </CardContent>
      </Card>

      <Card>
        <CardHeader>
          <CardTitle>{t("masters.productEnquiryConfig.filtersTitle")}</CardTitle>
        </CardHeader>
        <CardContent>
          <FieldListSection orgId={orgId} kind="filter" attributeKeys={activeAttributeKeys} />
        </CardContent>
      </Card>

      <Card>
        <CardHeader>
          <CardTitle>{t("masters.productEnquiryConfig.comparisonFieldsTitle")}</CardTitle>
        </CardHeader>
        <CardContent>
          <FieldListSection orgId={orgId} kind="comparison" attributeKeys={activeAttributeKeys} />
        </CardContent>
      </Card>

      <Card>
        <CardHeader>
          <CardTitle>{t("masters.productEnquiryConfig.ctaTitle")}</CardTitle>
        </CardHeader>
        <CardContent>
          <CtaSection orgId={orgId} />
        </CardContent>
      </Card>

      <Card>
        <CardHeader>
          <CardTitle>{t("masters.productEnquiryConfig.attributeKeysTitle")}</CardTitle>
        </CardHeader>
        <CardContent>
          <AttributeKeysSection orgId={orgId} />
        </CardContent>
      </Card>
    </div>
  )
}

function TabsSection({ orgId }: { orgId: string | undefined }) {
  const { t } = useTranslation()
  const { data: rows, isLoading, isError, refetch } = productEnquiryTabsHooks.useList(orgId)
  const createMut = productEnquiryTabsHooks.useCreate()
  const updateMut = productEnquiryTabsHooks.useUpdate()
  const deleteMut = productEnquiryTabsHooks.useDelete()

  const fields: CrudFieldDef[] = [
    {
      key: "tab_type",
      label: t("masters.productEnquiryConfig.tabType"),
      type: "select",
      options: TAB_TYPES.map((tt) => ({ value: tt, label: t(`masters.productEnquiryConfig.tabTypes.${tt}`) })),
    },
    { key: "label", label: t("masters.productEnquiryConfig.label"), type: "text", required: true },
  ]

  return (
    <ReorderableListCard<Tables<"product_enquiry_tabs">>
      fields={fields}
      rows={rows ?? []}
      getId={(r) => r.id}
      getLabel={(r) => r.label}
      getMeta={(r) => `(${t(`masters.productEnquiryConfig.tabTypes.${r.tab_type}`)})`}
      getSortOrder={(r) => r.sort_order}
      getIsActive={(r) => r.is_active}
      loading={isLoading}
      error={isError ? t("masters.loadFailed") : null}
      onRetry={() => refetch()}
      isMutating={createMut.isPending || updateMut.isPending}
      addLabel={t("masters.productEnquiryConfig.addTab")}
      emptyMessage={t("masters.productEnquiryConfig.tabsEmpty")}
      toFormValues={(r) => ({ tab_type: r.tab_type, label: r.label, topics: toStringArray(r.config && (r.config as Record<string, Json>).topics).join(",") })}
      renderExtra={(values, setValues) =>
        values.tab_type === "video_library" ? (
          <div className="space-y-1">
            <p className="text-xs font-medium text-text-muted">{t("masters.productEnquiryConfig.topics")}</p>
            <div className="flex flex-wrap gap-1.5">
              {TOPICS.map((topic) => {
                const selected = new Set((values.topics ?? "").split(",").filter(Boolean))
                const active = selected.has(topic)
                return (
                  <button
                    key={topic}
                    type="button"
                    onClick={() => {
                      const next = new Set(selected)
                      if (active) next.delete(topic)
                      else next.add(topic)
                      setValues((v) => ({ ...v, topics: Array.from(next).join(",") }))
                    }}
                    className={`rounded-full border px-2.5 py-1 text-xs font-medium ${
                      active ? "border-accent bg-accent text-white" : "border-border text-text-muted"
                    }`}
                  >
                    {t(`customerApp.productEnquiry.topics.${topic}`)}
                  </button>
                )
              })}
            </div>
          </div>
        ) : null
      }
      onCreate={(v) =>
        createMut.mutateAsync({
          org_id: orgId!,
          tab_type: v.tab_type as Enums<"product_enquiry_tab_type">,
          label: v.label,
          config: v.tab_type === "video_library" ? { topics: (v.topics ?? "").split(",").filter(Boolean) } : {},
        })
      }
      onUpdate={(id, v) =>
        updateMut.mutateAsync({
          id,
          patch: {
            tab_type: v.tab_type as Enums<"product_enquiry_tab_type">,
            label: v.label,
            config: v.tab_type === "video_library" ? { topics: (v.topics ?? "").split(",").filter(Boolean) } : {},
          },
        })
      }
      onDelete={(id) => deleteMut.mutateAsync(id)}
      onToggleActive={(id, next) => updateMut.mutateAsync({ id, patch: { is_active: next } })}
      onReorder={(id, sortOrder) => updateMut.mutateAsync({ id, patch: { sort_order: sortOrder } })}
    />
  )
}

type FieldRow = Tables<"product_enquiry_filters"> | Tables<"product_enquiry_comparison_fields">

function FieldListSection({
  orgId,
  kind,
  attributeKeys,
}: {
  orgId: string | undefined
  kind: "filter" | "comparison"
  attributeKeys: Tables<"product_attribute_keys">[]
}) {
  const { t } = useTranslation()
  const hooks = kind === "filter" ? productEnquiryFiltersHooks : productEnquiryComparisonFieldsHooks
  const { data: rows, isLoading, isError, refetch } = hooks.useList(orgId)
  const createMut = hooks.useCreate()
  const updateMut = hooks.useUpdate()
  const deleteMut = hooks.useDelete()

  const fields: CrudFieldDef[] = [
    {
      key: "source",
      label: t("masters.productEnquiryConfig.source"),
      type: "select",
      options: [
        { value: "product_field", label: t("masters.productEnquiryConfig.sourceProductField") },
        { value: "attribute_key", label: t("masters.productEnquiryConfig.sourceAttribute") },
      ],
    },
    {
      key: "target",
      label: t("masters.productEnquiryConfig.field"),
      type: "select",
      options: (values) =>
        values.source === "attribute_key"
          ? attributeKeys.map((k) => ({ value: k.id, label: k.label }))
          : PRODUCT_FIELDS.map((pf) => ({ value: pf, label: t(`masters.productEnquiryConfig.productFields.${pf}`) })),
    },
    { key: "label", label: t("masters.productEnquiryConfig.label"), type: "text", required: true },
  ]

  return (
    <ReorderableListCard<FieldRow>
      fields={fields}
      rows={rows ?? []}
      getId={(r) => r.id}
      getLabel={(r) => r.label}
      getMeta={(r) => (r.attribute_key_id ? `(${t("masters.productEnquiryConfig.sourceAttribute")})` : null)}
      getSortOrder={(r) => r.sort_order}
      getIsActive={(r) => r.is_active}
      loading={isLoading}
      error={isError ? t("masters.loadFailed") : null}
      onRetry={() => refetch()}
      isMutating={createMut.isPending || updateMut.isPending}
      addLabel={kind === "filter" ? t("masters.productEnquiryConfig.addFilter") : t("masters.productEnquiryConfig.addComparisonField")}
      emptyMessage={kind === "filter" ? t("masters.productEnquiryConfig.filtersEmpty") : t("masters.productEnquiryConfig.comparisonFieldsEmpty")}
      toFormValues={(r) => ({
        source: r.attribute_key_id ? "attribute_key" : "product_field",
        target: r.attribute_key_id ?? r.product_field ?? "",
        label: r.label,
      })}
      onCreate={(v) =>
        createMut.mutateAsync({
          org_id: orgId!,
          product_field: v.source === "product_field" ? (v.target as Enums<"product_enquiry_field">) : null,
          attribute_key_id: v.source === "attribute_key" ? v.target : null,
          label: v.label,
        })
      }
      onUpdate={(id, v) =>
        updateMut.mutateAsync({
          id,
          patch: {
            product_field: v.source === "product_field" ? (v.target as Enums<"product_enquiry_field">) : null,
            attribute_key_id: v.source === "attribute_key" ? v.target : null,
            label: v.label,
          },
        })
      }
      onDelete={(id) => deleteMut.mutateAsync(id)}
      onToggleActive={(id, next) => updateMut.mutateAsync({ id, patch: { is_active: next } })}
      onReorder={(id, sortOrder) => updateMut.mutateAsync({ id, patch: { sort_order: sortOrder } })}
    />
  )
}

function CtaSection({ orgId }: { orgId: string | undefined }) {
  const { t } = useTranslation()
  const { data: rows, isLoading, isError, refetch } = productEnquiryCtaConfigHooks.useList(orgId)
  const createMut = productEnquiryCtaConfigHooks.useCreate()
  const updateMut = productEnquiryCtaConfigHooks.useUpdate()
  const deleteMut = productEnquiryCtaConfigHooks.useDelete()

  const fields: CrudFieldDef[] = [
    {
      key: "cta_type",
      label: t("masters.productEnquiryConfig.ctaType"),
      type: "select",
      options: CTA_TYPES.map((ct) => ({ value: ct, label: t(`masters.productCtaOverrides.ctaType.${ct}`) })),
    },
    { key: "label", label: t("masters.productEnquiryConfig.label"), type: "text", required: true },
  ]

  function configFor(v: Record<string, string>): Json {
    if (v.cta_type === "quotation") {
      return {
        qty_stepper_enabled: v.qty_stepper_enabled !== "false",
        min_qty: Number(v.min_qty) || 1,
        max_qty: Number(v.max_qty) || 10,
        note_field_enabled: v.note_field_enabled !== "false",
      }
    }
    if (v.cta_type === "callback") {
      return { max_days_ahead: Number(v.max_days_ahead) || 15 }
    }
    return { fields: (v.share_fields ?? "").split(",").filter(Boolean) }
  }

  return (
    <ReorderableListCard<Tables<"product_enquiry_cta_config">>
      fields={fields}
      rows={rows ?? []}
      getId={(r) => r.id}
      getLabel={(r) => r.label}
      getMeta={(r) => `(${t(`masters.productCtaOverrides.ctaType.${r.cta_type}`)})`}
      getSortOrder={(r) => r.sort_order}
      getIsActive={(r) => r.is_active}
      loading={isLoading}
      error={isError ? t("masters.loadFailed") : null}
      onRetry={() => refetch()}
      isMutating={createMut.isPending || updateMut.isPending}
      addLabel={t("masters.productEnquiryConfig.addCta")}
      emptyMessage={t("masters.productEnquiryConfig.ctaEmpty")}
      toFormValues={(r) => {
        const cfg = (r.config ?? {}) as Record<string, Json>
        return {
          cta_type: r.cta_type,
          label: r.label,
          min_qty: cfg.min_qty != null ? String(cfg.min_qty) : "1",
          max_qty: cfg.max_qty != null ? String(cfg.max_qty) : "10",
          qty_stepper_enabled: String(cfg.qty_stepper_enabled !== false),
          note_field_enabled: String(cfg.note_field_enabled !== false),
          max_days_ahead: cfg.max_days_ahead != null ? String(cfg.max_days_ahead) : "15",
          share_fields: toStringArray(cfg.fields).join(","),
        }
      }}
      renderExtra={(values, setValues) => {
        if (values.cta_type === "quotation") {
          return (
            <div className="grid grid-cols-2 gap-2">
              <label className="space-y-1 text-xs text-text-muted">
                {t("masters.productEnquiryConfig.minQty")}
                <input
                  type="number"
                  value={values.min_qty ?? "1"}
                  onChange={(e) => setValues((v) => ({ ...v, min_qty: e.target.value }))}
                  className="mt-1 h-9 w-full rounded-xl border border-border bg-surface px-3 text-sm text-text outline-none"
                />
              </label>
              <label className="space-y-1 text-xs text-text-muted">
                {t("masters.productEnquiryConfig.maxQty")}
                <input
                  type="number"
                  value={values.max_qty ?? "10"}
                  onChange={(e) => setValues((v) => ({ ...v, max_qty: e.target.value }))}
                  className="mt-1 h-9 w-full rounded-xl border border-border bg-surface px-3 text-sm text-text outline-none"
                />
              </label>
            </div>
          )
        }
        if (values.cta_type === "callback") {
          return (
            <label className="space-y-1 text-xs text-text-muted">
              {t("masters.productEnquiryConfig.maxDaysAhead")}
              <input
                type="number"
                value={values.max_days_ahead ?? "15"}
                onChange={(e) => setValues((v) => ({ ...v, max_days_ahead: e.target.value }))}
                className="mt-1 h-9 w-full rounded-xl border border-border bg-surface px-3 text-sm text-text outline-none"
              />
            </label>
          )
        }
        return (
          <div className="space-y-1">
            <p className="text-xs font-medium text-text-muted">{t("masters.productEnquiryConfig.shareFields")}</p>
            <div className="flex flex-wrap gap-1.5">
              {(["name", "price", "emi", "brand"] as const).map((f) => {
                const selected = new Set((values.share_fields ?? "").split(",").filter(Boolean))
                const active = selected.has(f)
                return (
                  <button
                    key={f}
                    type="button"
                    onClick={() => {
                      const next = new Set(selected)
                      if (active) next.delete(f)
                      else next.add(f)
                      setValues((v) => ({ ...v, share_fields: Array.from(next).join(",") }))
                    }}
                    className={`rounded-full border px-2.5 py-1 text-xs font-medium ${
                      active ? "border-accent bg-accent text-white" : "border-border text-text-muted"
                    }`}
                  >
                    {t(`masters.productEnquiryConfig.shareField.${f}`)}
                  </button>
                )
              })}
            </div>
          </div>
        )
      }}
      onCreate={(v) =>
        createMut.mutateAsync({
          org_id: orgId!,
          cta_type: v.cta_type as Enums<"product_enquiry_cta_type">,
          label: v.label,
          config: configFor(v),
        })
      }
      onUpdate={(id, v) =>
        updateMut.mutateAsync({
          id,
          patch: { cta_type: v.cta_type as Enums<"product_enquiry_cta_type">, label: v.label, config: configFor(v) },
        })
      }
      onDelete={(id) => deleteMut.mutateAsync(id)}
      onToggleActive={(id, next) => updateMut.mutateAsync({ id, patch: { is_active: next } })}
      onReorder={(id, sortOrder) => updateMut.mutateAsync({ id, patch: { sort_order: sortOrder } })}
    />
  )
}

function AttributeKeysSection({ orgId }: { orgId: string | undefined }) {
  const { t } = useTranslation()
  const { data: rows, isLoading, isError, refetch } = productAttributeKeysHooks.useList(orgId)
  const createMut = productAttributeKeysHooks.useCreate()
  const updateMut = productAttributeKeysHooks.useUpdate()
  const deleteMut = productAttributeKeysHooks.useDelete()

  const fields: CrudFieldDef[] = [
    { key: "label", label: t("masters.productAttributes.newKeyLabel"), type: "text", required: true },
    { key: "key_name", label: t("masters.productEnquiryConfig.keyName"), type: "text", required: true },
    {
      key: "data_type",
      label: t("masters.productEnquiryConfig.dataType"),
      type: "select",
      options: [
        { value: "text", label: t("masters.productAttributes.dataType.text") },
        { value: "number", label: t("masters.productAttributes.dataType.number") },
        { value: "boolean", label: t("masters.productAttributes.dataType.boolean") },
      ],
    },
  ]

  return (
    <EntityCrudTable<Tables<"product_attribute_keys">>
      fields={fields}
      rows={rows ?? []}
      getId={(r) => r.id}
      loading={isLoading}
      error={isError ? t("masters.loadFailed") : null}
      onRetry={() => refetch()}
      isMutating={createMut.isPending || updateMut.isPending}
      addLabel={t("masters.productEnquiryConfig.addAttributeKey")}
      emptyMessage={t("masters.productEnquiryConfig.attributeKeysEmpty")}
      toFormValues={(r) => ({ label: r.label, key_name: r.key_name, data_type: r.data_type })}
      columns={[
        { key: "label", header: t("masters.productAttributes.newKeyLabel"), render: (r) => <span className="font-medium text-text">{r.label}</span> },
        { key: "key_name", header: t("masters.productEnquiryConfig.keyName"), render: (r) => r.key_name },
        { key: "data_type", header: t("masters.productEnquiryConfig.dataType"), render: (r) => t(`masters.productAttributes.dataType.${r.data_type}`) },
        {
          key: "is_active",
          header: t("masters.products.status"),
          render: (r) => (
            <button
              type="button"
              disabled={updateMut.isPending}
              onClick={() => updateMut.mutate({ id: r.id, patch: { is_active: !r.is_active } })}
              className={`rounded-full px-2 py-0.5 text-xs font-semibold ${r.is_active ? "bg-success/10 text-success" : "bg-danger/10 text-danger"}`}
            >
              {r.is_active ? t("masters.active") : t("masters.inactive")}
            </button>
          ),
        },
      ]}
      onCreate={(v) => createMut.mutateAsync({ org_id: orgId!, label: v.label, key_name: v.key_name, data_type: v.data_type })}
      onUpdate={(id, v) => updateMut.mutateAsync({ id, patch: { label: v.label, key_name: v.key_name, data_type: v.data_type } })}
      onDelete={(id) => deleteMut.mutateAsync(id)}
    />
  )
}
