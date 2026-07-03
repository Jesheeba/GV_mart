import { useTranslation } from "react-i18next"
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs"
import { Card } from "@/components/ui/card"
import { BrandsTab } from "./BrandsTab"
import { ModelsTab } from "./ModelsTab"
import { ProductsTab } from "./ProductsTab"
import { SparesTab } from "./SparesTab"
import { GiftsTab } from "./GiftsTab"
import { AmcPlansTab } from "./AmcPlansTab"
import { IncentiveRulesTab } from "./IncentiveRulesTab"
import { SettingsTab } from "./SettingsTab"

export function MastersPage() {
  const { t } = useTranslation()

  return (
    <div className="space-y-4 pt-2">
      <div>
        <h1 className="text-2xl font-bold text-text">{t("nav.masters")}</h1>
        <p className="text-sm text-text-muted">{t("masters.subtitle")}</p>
      </div>

      <Tabs defaultValue="brands">
        <TabsList className="flex-wrap">
          <TabsTrigger value="brands">{t("masters.tabs.brands")}</TabsTrigger>
          <TabsTrigger value="models">{t("masters.tabs.models")}</TabsTrigger>
          <TabsTrigger value="products">{t("masters.tabs.products")}</TabsTrigger>
          <TabsTrigger value="spares">{t("masters.tabs.spares")}</TabsTrigger>
          <TabsTrigger value="gifts">{t("masters.tabs.gifts")}</TabsTrigger>
          <TabsTrigger value="amcPlans">{t("masters.tabs.amcPlans")}</TabsTrigger>
          <TabsTrigger value="incentives">{t("masters.tabs.incentives")}</TabsTrigger>
          <TabsTrigger value="settings">{t("masters.tabs.settings")}</TabsTrigger>
        </TabsList>

        <Card size="default" className="mt-3">
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
          <TabsContent value="settings">
            <SettingsTab />
          </TabsContent>
        </Card>
      </Tabs>
    </div>
  )
}
