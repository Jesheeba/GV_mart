import { useState } from "react"
import { useTranslation } from "react-i18next"
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs"
import { Card } from "@/components/ui/card"
import { SegButton } from "@/components/shared/SegButton"
import { SalaryTab } from "./SalaryTab"
import { StaffSalaryTab } from "./StaffSalaryTab"
import { IncentivesTab } from "./IncentivesTab"
import { RewardsTab } from "./RewardsTab"

// 2026-10-28 nav audit: Salary and Staff Salary used to be two separate tabs
// even though both just write to the same `expenses` (category='salary')
// ledger for different staff types (technician vs everyone else) — see
// SalaryTab.tsx / StaffSalaryTab.tsx. Merged into one "Salary" tab with a
// Technician/Staff toggle; no data model or write-path change, UI only.
export function HrPage() {
  const { t } = useTranslation()
  const [salaryAudience, setSalaryAudience] = useState<"technician" | "staff">("technician")

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
          <TabsContent value="salary" className="space-y-4">
            <div className="flex gap-[3px] self-start rounded-full border border-border bg-surface-alt p-1">
              <SegButton active={salaryAudience === "technician"} onClick={() => setSalaryAudience("technician")}>
                {t("hr.salary.technician")}
              </SegButton>
              <SegButton active={salaryAudience === "staff"} onClick={() => setSalaryAudience("staff")}>
                {t("hr.tabs.staffSalary")}
              </SegButton>
            </div>
            {salaryAudience === "technician" ? <SalaryTab /> : <StaffSalaryTab />}
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
