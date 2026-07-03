import { useTranslation } from "react-i18next"
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs"
import { Card } from "@/components/ui/card"
import { InventoryTable } from "./InventoryTable"

export function InventoryPage() {
  const { t } = useTranslation()

  return (
    <div className="space-y-4 pt-2">
      <div>
        <h1 className="text-2xl font-bold text-text">{t("nav.inventory")}</h1>
        <p className="text-sm text-text-muted">{t("inventory.subtitle")}</p>
      </div>

      <Tabs defaultValue="products">
        <TabsList>
          <TabsTrigger value="products">{t("masters.tabs.products")}</TabsTrigger>
          <TabsTrigger value="spares">{t("masters.tabs.spares")}</TabsTrigger>
        </TabsList>
        <Card size="default" className="mt-3">
          <TabsContent value="products">
            <InventoryTable itemType="product" />
          </TabsContent>
          <TabsContent value="spares">
            <InventoryTable itemType="spare" />
          </TabsContent>
        </Card>
      </Tabs>
    </div>
  )
}
