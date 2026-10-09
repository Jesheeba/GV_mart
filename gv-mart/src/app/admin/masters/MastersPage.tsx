import { useState } from "react"
import { useTranslation } from "react-i18next"
import { Ban, PhoneCall, Megaphone, CalendarClock, CheckSquare, ClipboardList, Droplet, Gift, Hammer, Layers, Package, QrCode, ShieldCheck, SlidersHorizontal, SquareStack, Tag, TrendingUp, Wallet, Wrench } from "lucide-react"
import { Tabs, TabsContent } from "@/components/ui/tabs"
import { Card } from "@/components/ui/card"
import { useProfile } from "@/hooks/useProfile"
import { MissingProductAlert } from "@/components/shared/MissingProductAlert"
import {
  amcPlansHooks,
  brandsHooks,
  complaintTypesHooks,
  giftExclusionProductsHooks,
  giftsHooks,
  incentiveRulesHooks,
  roleBaseSalariesHooks,
  installationRatesHooks,
  leadKindsHooks,
  leadProductTypesHooks,
  leadSourcesHooks,
  modelsHooks,
  productEnquiryTabsHooks,
  productsHooks,
  rentalPlansHooks,
  sopStepTemplatesHooks,
  sparesHooks,
  waterQualityReferenceHooks,
} from "@/hooks/useMasters"
import { cn } from "@/lib/utils"
import { BrandsTab } from "./BrandsTab"
import { ModelsTab } from "./ModelsTab"
import { ProductsTab } from "./ProductsTab"
import { SparesTab } from "./SparesTab"
import { GiftsTab } from "./GiftsTab"
import { GiftExclusionsTab } from "./GiftExclusionsTab"
import { AmcPlansTab } from "./AmcPlansTab"
import { RentalPlansTab } from "./RentalPlansTab"
import { useTechnicianTiers } from "@/hooks/useTechnicianTiers"
import { TechnicianTiersTab } from "./TechnicianTiersTab"
import { IncentiveRulesTab } from "./IncentiveRulesTab"
import { RoleSalariesTab } from "./RoleSalariesTab"
import { InstallationRatesTab } from "./InstallationRatesTab"
import { ComplaintTypesTab } from "./ComplaintTypesTab"
import { SopStepsTab } from "./SopStepsTab"
import { ProductEnquiryConfigTab } from "./ProductEnquiryConfigTab"
import { SettingsTab } from "./SettingsTab"
import { PaymentSettingsTab } from "./PaymentSettingsTab"
import { WaterQualityTab } from "./WaterQualityTab"
import { LeadSourcesTab } from "./LeadSourcesTab"
import { LeadKindsTab } from "./LeadKindsTab"
import { LeadProductTypesTab } from "./LeadProductTypesTab"
import { LeadOutcomesTab } from "./LeadOutcomesTab"
import { useLeadOutcomes } from "@/hooks/useLeadFollowups"

type ModuleId =
  | "brands"
  | "models"
  | "products"
  | "spares"
  | "gifts"
  | "giftExclusions"
  | "amcPlans"
  | "rentalPlans"
  | "technicianTiers"
  | "incentives"
  | "roleSalaries"
  | "installationRates"
  | "complaintTypes"
  | "sopSteps"
  | "productEnquiry"
  | "waterQuality"
  | "leadSources"
  | "leadKinds"
  | "leadProductTypes"
  | "leadOutcomes"
  | "settings"
  | "paymentSettings"

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
  const { data: giftExclusionProducts } = giftExclusionProductsHooks.useList(orgId)
  const { data: amcPlans } = amcPlansHooks.useList(orgId)
  const { data: rentalPlans } = rentalPlansHooks.useList(orgId)
  const { data: technicianTiers } = useTechnicianTiers(orgId)
  const { data: incentiveRules } = incentiveRulesHooks.useList(orgId)
  const { data: roleSalaries } = roleBaseSalariesHooks.useList(orgId)
  const { data: installationRates } = installationRatesHooks.useList(orgId)
  const { data: complaintTypes } = complaintTypesHooks.useList(orgId)
  const { data: sopStepTemplates } = sopStepTemplatesHooks.useList(orgId)
  const { data: productEnquiryTabs } = productEnquiryTabsHooks.useList(orgId)
  const { data: leadSources } = leadSourcesHooks.useList(orgId)
  const { data: leadKinds } = leadKindsHooks.useList(orgId)
  const { data: leadProductTypes } = leadProductTypesHooks.useList(orgId)
  const { data: leadOutcomes } = useLeadOutcomes(orgId)
  const { data: waterQualityDistricts } = waterQualityReferenceHooks.useList(orgId)
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
    {
      id: "giftExclusions",
      icon: Ban,
      swatch: "warning",
      title: t("masters.tabs.giftExclusions"),
      desc: t("masters.overview.giftExclusionsDesc", { count: giftExclusionProducts?.length ?? 0 }),
    },
    { id: "amcPlans", icon: ShieldCheck, swatch: "info", title: t("masters.tabs.amcPlans"), desc: t("masters.overview.amcPlansDesc", { count: amcPlans?.length ?? 0 }) },
    { id: "rentalPlans", icon: CalendarClock, swatch: "warning", title: t("masters.tabs.rentalPlans"), desc: t("masters.overview.rentalPlansDesc", { count: rentalPlans?.length ?? 0 }) },
    { id: "technicianTiers", icon: TrendingUp, swatch: "accent", title: t("masters.tabs.technicianTiers"), desc: t("masters.overview.technicianTiersDesc", { count: technicianTiers?.length ?? 0 }) },
    { id: "incentives", icon: TrendingUp, swatch: "green", title: t("masters.tabs.incentives"), desc: t("masters.overview.incentivesDesc", { count: incentiveRules?.length ?? 0 }) },
    { id: "installationRates", icon: Hammer, swatch: "green", title: t("masters.tabs.installationRates"), desc: t("masters.overview.installationRatesDesc", { count: installationRates?.length ?? 0 }) },
    { id: "roleSalaries", icon: Wallet, swatch: "info", title: t("masters.tabs.roleSalaries"), desc: t("masters.overview.roleSalariesDesc", { count: roleSalaries?.length ?? 0 }) },
    { id: "complaintTypes", icon: ClipboardList, swatch: "accent", title: t("masters.tabs.complaintTypes"), desc: t("masters.overview.complaintTypesDesc", { count: complaintTypeDefaultsCount }) },
    { id: "sopSteps", icon: CheckSquare, swatch: "info", title: t("masters.tabs.sopSteps"), desc: t("masters.overview.sopStepsDesc", { count: sopStepTemplates?.length ?? 0 }) },
    {
      id: "productEnquiry",
      icon: SquareStack,
      swatch: "accent",
      title: t("masters.tabs.productEnquiry"),
      desc: t("masters.overview.productEnquiryDesc", { count: productEnquiryTabs?.length ?? 0 }),
    },
    {
      id: "waterQuality",
      icon: Droplet,
      swatch: "info",
      title: t("masters.tabs.waterQuality"),
      desc: t("masters.overview.waterQualityDesc", { count: waterQualityDistricts?.length ?? 0 }),
    },
    { id: "leadSources", icon: Megaphone, swatch: "accent", title: t("masters.tabs.leadSources"), desc: t("masters.overview.leadSourcesDesc", { count: leadSources?.length ?? 0 }) },
    { id: "leadKinds", icon: Tag, swatch: "info", title: t("masters.tabs.leadKinds"), desc: t("masters.overview.leadKindsDesc", { count: leadKinds?.length ?? 0 }) },
    {
      id: "leadProductTypes",
      icon: Package,
      swatch: "info",
      title: t("masters.tabs.leadProductTypes"),
      desc: t("masters.overview.leadProductTypesDesc", { count: leadProductTypes?.length ?? 0 }),
    },
    { id: "leadOutcomes", icon: PhoneCall, swatch: "green", title: t("masters.tabs.leadOutcomes"), desc: t("masters.overview.leadOutcomesDesc", { count: leadOutcomes?.length ?? 0 }) },
    { id: "settings", icon: SlidersHorizontal, swatch: "warning", title: t("masters.tabs.settings"), desc: t("masters.overview.settingsDesc") },
    { id: "paymentSettings", icon: QrCode, swatch: "green", title: t("masters.tabs.paymentSettings"), desc: t("masters.overview.paymentSettingsDesc") },
  ]

  return (
    <div className="space-y-4 pt-2">
      <div className="mb-1">
        <h1 className="mb-1.5 text-[28px] leading-[1.05] font-extrabold tracking-tight text-text">{t("masters.pageTitle")}</h1>
        <p className="text-sm font-medium text-text-muted">{t("masters.subtitle")}</p>
      </div>

      <MissingProductAlert orgId={orgId} />

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
          <TabsContent value="giftExclusions">
            <GiftExclusionsTab />
          </TabsContent>
          <TabsContent value="amcPlans">
            <AmcPlansTab />
          </TabsContent>
          <TabsContent value="rentalPlans">
            <RentalPlansTab />
          </TabsContent>
          <TabsContent value="technicianTiers">
            <TechnicianTiersTab />
          </TabsContent>
          <TabsContent value="incentives">
            <IncentiveRulesTab />
          </TabsContent>
          <TabsContent value="installationRates">
            <InstallationRatesTab />
          </TabsContent>
          <TabsContent value="roleSalaries">
            <RoleSalariesTab />
          </TabsContent>
          <TabsContent value="complaintTypes">
            <ComplaintTypesTab />
          </TabsContent>
          <TabsContent value="sopSteps">
            <SopStepsTab />
          </TabsContent>
          <TabsContent value="productEnquiry">
            <ProductEnquiryConfigTab />
          </TabsContent>
          <TabsContent value="waterQuality">
            <WaterQualityTab />
          </TabsContent>
          <TabsContent value="leadSources">
            <LeadSourcesTab />
          </TabsContent>
          <TabsContent value="leadKinds">
            <LeadKindsTab />
          </TabsContent>
          <TabsContent value="leadProductTypes">
            <LeadProductTypesTab />
          </TabsContent>
          <TabsContent value="leadOutcomes">
            <LeadOutcomesTab />
          </TabsContent>
          <TabsContent value="settings">
            <SettingsTab />
          </TabsContent>
          <TabsContent value="paymentSettings">
            <PaymentSettingsTab />
          </TabsContent>
        </Card>
      </Tabs>
    </div>
  )
}
