import { useTranslation } from "react-i18next"
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs"
import { PurchaseOrdersTab } from "./PurchaseOrdersTab"
import { BillEntryTab } from "./BillEntryTab"
import { PurchaseQuotesTab } from "./PurchaseQuotesTab"

export function PurchasePage() {
  const { t } = useTranslation()

  return (
    <div className="space-y-4 pt-2">
      <div>
        <h1 className="text-2xl font-bold text-text">{t("nav.purchase")}</h1>
        <p className="text-sm text-text-muted">{t("purchase.subtitle")}</p>
      </div>

      <Tabs defaultValue="orders">
        <TabsList>
          <TabsTrigger value="orders">{t("purchase.tabs.orders")}</TabsTrigger>
          <TabsTrigger value="quotes">{t("purchase.tabs.quotes")}</TabsTrigger>
          <TabsTrigger value="bills">{t("purchase.tabs.bills")}</TabsTrigger>
        </TabsList>
        <TabsContent value="orders" className="mt-3">
          <PurchaseOrdersTab />
        </TabsContent>
        <TabsContent value="quotes" className="mt-3">
          <PurchaseQuotesTab />
        </TabsContent>
        <TabsContent value="bills" className="mt-3">
          <BillEntryTab />
        </TabsContent>
      </Tabs>
    </div>
  )
}
