import { useTranslation } from "react-i18next"
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs"
import { Card } from "@/components/ui/card"
import { SalesServiceReportTab } from "./SalesServiceReportTab"
import { PnlReportTab } from "./PnlReportTab"
import { PerformanceReportTab } from "./PerformanceReportTab"
import { FeedbackReportTab } from "./FeedbackReportTab"

export function ReportsPage() {
  const { t } = useTranslation()

  return (
    <div className="space-y-4 pt-2">
      <div>
        <h1 className="text-2xl font-bold text-text">{t("nav.reports")}</h1>
        <p className="text-sm text-text-muted">{t("reports.subtitle")}</p>
      </div>

      <Tabs defaultValue="salesService">
        <TabsList className="flex-wrap">
          <TabsTrigger value="salesService">{t("reports.tabs.salesService")}</TabsTrigger>
          <TabsTrigger value="pnl">{t("reports.tabs.pnl")}</TabsTrigger>
          <TabsTrigger value="performance">{t("reports.tabs.performance")}</TabsTrigger>
          <TabsTrigger value="feedback">{t("reports.tabs.feedback")}</TabsTrigger>
        </TabsList>

        <Card size="default" className="mt-3">
          <TabsContent value="salesService">
            <SalesServiceReportTab />
          </TabsContent>
          <TabsContent value="pnl">
            <PnlReportTab />
          </TabsContent>
          <TabsContent value="performance">
            <PerformanceReportTab />
          </TabsContent>
          <TabsContent value="feedback">
            <FeedbackReportTab />
          </TabsContent>
        </Card>
      </Tabs>
    </div>
  )
}
