import { useTranslation } from "react-i18next"
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs"
import { Card } from "@/components/ui/card"
import { VerificationQueueTab } from "./VerificationQueueTab"
import { BikeAssignmentTab } from "./BikeAssignmentTab"
import { KmLogTab } from "./KmLogTab"
import { AllowancesTab } from "./AllowancesTab"
import { AdjustmentsTab } from "./AdjustmentsTab"
import { SettingsTab } from "./SettingsTab"

/** Monthly Expenses spec (GVMART_MONTHLY_EXPENSES_SPEC.md) — admin screen,
 *  same Tabs/TabsContent/Card structure as src/app/admin/hr/HrPage.tsx. */
export function ExpensesPage() {
  const { t } = useTranslation()

  return (
    <div className="space-y-4 pt-2">
      <div>
        <h1 className="text-2xl font-bold text-text">{t("nav.expenses")}</h1>
        <p className="text-sm text-text-muted">{t("expenses.subtitle")}</p>
      </div>

      <Tabs defaultValue="verification">
        <TabsList>
          <TabsTrigger value="verification">{t("expenses.tabs.verification")}</TabsTrigger>
          <TabsTrigger value="bikeAssignment">{t("expenses.tabs.bikeAssignment")}</TabsTrigger>
          <TabsTrigger value="kmLog">{t("expenses.tabs.kmLog")}</TabsTrigger>
          <TabsTrigger value="allowances">{t("expenses.tabs.allowances")}</TabsTrigger>
          <TabsTrigger value="adjustments">{t("expenses.tabs.adjustments")}</TabsTrigger>
          <TabsTrigger value="settings">{t("expenses.tabs.settings")}</TabsTrigger>
        </TabsList>

        <Card size="default" className="mt-3">
          <TabsContent value="verification">
            <VerificationQueueTab />
          </TabsContent>
          <TabsContent value="bikeAssignment">
            <BikeAssignmentTab />
          </TabsContent>
          <TabsContent value="kmLog">
            <KmLogTab />
          </TabsContent>
          <TabsContent value="allowances">
            <AllowancesTab />
          </TabsContent>
          <TabsContent value="adjustments">
            <AdjustmentsTab />
          </TabsContent>
          <TabsContent value="settings">
            <SettingsTab />
          </TabsContent>
        </Card>
      </Tabs>
    </div>
  )
}
