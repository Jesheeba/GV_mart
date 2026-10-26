import { useTranslation } from "react-i18next"
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs"
import { LeadSourcesTab } from "./LeadSourcesTab"
import { LeadKindsTab } from "./LeadKindsTab"
import { LeadProductTypesTab } from "./LeadProductTypesTab"

/**
 * Cleanup batch 1 item 3: Lead Sources, Lead Kinds and Lead Product Types
 * are three structurally identical small master lists edited together —
 * folded into one tab with sub-tabs rather than three separate masters
 * modules. Each sub-tab is still its own untouched component, same tables,
 * same writes.
 */
export function LeadTaxonomyTab() {
  const { t } = useTranslation()

  return (
    <Tabs defaultValue="leadSources">
      <TabsList>
        <TabsTrigger value="leadSources">{t("masters.tabs.leadSources")}</TabsTrigger>
        <TabsTrigger value="leadKinds">{t("masters.tabs.leadKinds")}</TabsTrigger>
        <TabsTrigger value="leadProductTypes">{t("masters.tabs.leadProductTypes")}</TabsTrigger>
      </TabsList>
      <TabsContent value="leadSources" className="mt-3">
        <LeadSourcesTab />
      </TabsContent>
      <TabsContent value="leadKinds" className="mt-3">
        <LeadKindsTab />
      </TabsContent>
      <TabsContent value="leadProductTypes" className="mt-3">
        <LeadProductTypesTab />
      </TabsContent>
    </Tabs>
  )
}
