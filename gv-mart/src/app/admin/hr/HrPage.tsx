import { useTranslation } from "react-i18next"
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs"
import { Card } from "@/components/ui/card"
import { SalaryTab } from "./SalaryTab"
import { IncentivesTab } from "./IncentivesTab"
import { RewardsTab } from "./RewardsTab"

export function HrPage() {
  const { t } = useTranslation()

  return (
    <div className="space-y-4 pt-2">
      <div>
        <h1 className="text-2xl font-bold text-text">{t("nav.hr")}</h1>
        <p className="text-sm text-text-muted">{t("hr.subtitle")}</p>
      </div>

      <Tabs defaultValue="salary">
        <TabsList>
          <TabsTrigger value="salary">{t("hr.tabs.salary")}</TabsTrigger>
          <TabsTrigger value="incentives">{t("hr.tabs.incentives")}</TabsTrigger>
          <TabsTrigger value="rewards">{t("hr.tabs.rewards")}</TabsTrigger>
        </TabsList>

        <Card size="default" className="mt-3">
          <TabsContent value="salary">
            <SalaryTab />
          </TabsContent>
          <TabsContent value="incentives">
            <IncentivesTab />
          </TabsContent>
          <TabsContent value="rewards">
            <RewardsTab />
          </TabsContent>
        </Card>
      </Tabs>
    </div>
  )
}
