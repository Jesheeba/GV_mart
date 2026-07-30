import { useState } from "react"
import { useTranslation } from "react-i18next"
import { ClipboardList, Gift, Layers, Package, ShieldCheck, SlidersHorizontal, Tag, TrendingUp, Wrench } from "lucide-react"
import { Tabs, TabsContent } from "@/components/ui/tabs"
import { Card } from "@/components/ui/card"
import { useProfile } from "@/hooks/useProfile"
import {
  amcPlansHooks,
  brandsHooks,
  complaintTypesHooks,
  giftsHooks,
  incentiveRulesHooks,
  modelsHooks,
  productsHooks,
  sparesHooks,
} from "@/hooks/useMasters"
import { cn } from "@/lib/utils"
import { BrandsTab } from "./BrandsTab"
import { ModelsTab } from "./ModelsTab"
import { ProductsTab } from "./ProductsTab"
import { SparesTab } from "./SparesTab"
import { GiftsTab } from "./GiftsTab"
import { AmcPlansTab } from "./AmcPlansTab"
import { IncentiveRulesTab } from "./IncentiveRulesTab"
import { ComplaintTypesTab } from "./ComplaintTypesTab"
import { SettingsTab } from "./SettingsTab"

type ModuleId = "brands" | "models" | "products" | "spares" | "gifts" | "amcPlans" | "incentives" | "complaintTypes" | "settings"

// Icon-swatch colors cycle through the design's palette (design-template-decoded.html
// line 1273-1278: orange / blue / green / amber / ink) — a presentational rotation,
// not tied to entity meaning, matching how the mockup itself repeats tones.
const SWATCH = {
  ink: "bg-[#F0EBE3] text-ink",
  accent: "bg-accent-soft text-accent",
  info: "bg-[#E6EEFC] text-info",
  green: "bg-[#E2F3EA] text-[#16855B]",
  warning: "bg-[#FCF1DF] text-warning",
} as const

export function MastersPage() {
  const { t } = useTranslation()
  const { data: profile } = useProfile()
  const orgId = profile?.org_id
  const [activeTab, setActiveTab] = useState<ModuleId>("products")

  const { data: brands } = brandsHooks.useList(orgId)
  const { data: models } = modelsHooks.useList(orgId)
  const { data: products } = productsHooks.useList(orgId)
  const { data: spares } = sparesHooks.useList(orgId)
  const { data: gifts } = giftsHooks.useList(orgId)
  const { data: amcPlans } = amcPlansHooks.useList(orgId)
  const { data: incentiveRules } = incentiveRulesHooks.useList(orgId)
  const { data: complaintTypes } = complaintTypesHooks.useList(orgId)
  // complaintTypes now also holds product-specific rows (product_id set),
  // managed from Inventory / Masters > Products, not from this tab. The
  // overview count should match what ComplaintTypesTab actually lists —
  // category-wide defaults only (product_id === null) — otherwise this
  // card's number would silently drift from the table beneath it.
  const complaintTypeDefaultsCount = (complaintTypes ?? []).filter((c) => c.product_id === null).length

  const modules: { id: ModuleId; icon: typeof Tag; swatch: keyof typeof SWATCH; title: string; desc: string }[] = [
    { id: "brands", icon: Tag, swatch: "ink", title: t("masters.tabs.brands"), desc: t("masters.overview.brandsDesc", { count: brands?.length ?? 0 }) },
    { id: "models", icon: Layers, swatch: "info", title: t("masters.tabs.models"), desc: t("masters.overview.modelsDesc", { count: models?.length ?? 0 }) },
    { id: "products", icon: Package, swatch: "accent", title: t("masters.tabs.products"), desc: t("masters.overview.productsDesc", { count: products?.length ?? 0 }) },
    { id: "spares", icon: Wrench, swatch: "ink", title: t("masters.tabs.spares"), desc: t("masters.overview.sparesDesc", { count: spares?.length ?? 0 }) },
    { id: "gifts", icon: Gift, swatch: "green", title: t("masters.tabs.gifts"), desc: t("masters.overview.giftsDesc", { count: gifts?.length ?? 0 }) },
    { id: "amcPlans", icon: ShieldCheck, swatch: "info", title: t("masters.tabs.amcPlans"), desc: t("masters.overview.amcPlansDesc", { count: amcPlans?.length ?? 0 }) },
    { id: "incentives", icon: TrendingUp, swatch: "green", title: t("masters.tabs.incentives"), desc: t("masters.overview.incentivesDesc", { count: incentiveRules?.length ?? 0 }) },
    { id: "complaintTypes", icon: ClipboardList, swatch: "accent", title: t("masters.tabs.complaintTypes"), desc: t("masters.overview.complaintTypesDesc", { count: complaintTypeDefaultsCount }) },
    { id: "settings", icon: SlidersHorizontal, swatch: "warning", title: t("masters.tabs.settings"), desc: t("masters.overview.settingsDesc") },
  ]

  return (
    <div className="space-y-4 pt-2">
      <div className="mb-1">
        <h1 className="mb-1.5 text-[28px] leading-[1.05] font-extrabold tracking-tight text-text">{t("masters.pageTitle")}</h1>
        <p className="text-sm font-medium text-text-muted">{t("masters.subtitle")}</p>
      </div>

      <Tabs value={activeTab} onValueChange={(v) => setActiveTab(v as ModuleId)}>
        <div className="grid grid-cols-1 gap-4.5 sm:grid-cols-2 lg:grid-cols-3">
          {modules.map((m) => (
            <button
              key={m.id}
              type="button"
              onClick={() => setActiveTab(m.id)}
              aria-pressed={activeTab === m.id}
              className={cn(
                "flex flex-col items-start rounded-card border bg-surface p-5.5 text-left shadow-[0_1px_2px_rgba(26,26,26,.04),0_14px_30px_-22px_rgba(26,26,26,.16)] transition-colors",
                activeTab === m.id ? "border-ink" : "border-border hover:border-[#DAD5CC]"
              )}
            >
              <span className={cn("mb-3.5 flex size-10.5 items-center justify-center rounded-[13px]", SWATCH[m.swatch])}>
                <m.icon className="size-5.5" strokeWidth={1.6} />
              </span>
              <h3 className="mb-1 text-[15px] font-bold text-text">{m.title}</h3>
              <p className="text-xs font-medium text-text-muted">{m.desc}</p>
            </button>
          ))}
        </div>

        <Card size="default" className="mt-4.5">
          <TabsContent value="brands">
            <BrandsTab />
          </TabsContent>
          <TabsContent value="models">
            <ModelsTab />
          </TabsContent>
          <TabsContent value="products">
            <ProductsTab />
          </TabsContent>
          <TabsContent value="spares">
            <SparesTab />
          </TabsContent>
          <TabsContent value="gifts">
            <GiftsTab />
          </TabsContent>
          <TabsContent value="amcPlans">
            <AmcPlansTab />
          </TabsContent>
          <TabsContent value="incentives">
            <IncentiveRulesTab />
          </TabsContent>
          <TabsContent value="complaintTypes">
            <ComplaintTypesTab />
          </TabsContent>
          <TabsContent value="settings">
            <SettingsTab />
          </TabsContent>
        </Card>
      </Tabs>
    </div>
  )
}
