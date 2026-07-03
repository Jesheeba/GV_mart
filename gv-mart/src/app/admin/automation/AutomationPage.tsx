import { useTranslation } from "react-i18next"
import { Card } from "@/components/ui/card"
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs"
import { AutomationFlowsTab } from "./AutomationFlowsTab"
import { VideoLibraryTab } from "./VideoLibraryTab"
import { InboundTestTab } from "./InboundTestTab"

export function AutomationPage() {
  const { t } = useTranslation()

  return (
    <div className="space-y-4 pt-2">
      <div>
        <h1 className="text-2xl font-bold text-text">{t("nav.automation")}</h1>
        <p className="text-sm text-text-muted">{t("automation.subtitle")}</p>
      </div>

      <Tabs defaultValue="flows">
        <TabsList>
          <TabsTrigger value="flows">{t("automation.tabs.flows")}</TabsTrigger>
          <TabsTrigger value="videos">{t("automation.tabs.videos")}</TabsTrigger>
          <TabsTrigger value="inbox">{t("automation.tabs.inbox")}</TabsTrigger>
        </TabsList>
        <Card size="default" className="mt-3">
          <TabsContent value="flows">
            <AutomationFlowsTab />
          </TabsContent>
          <TabsContent value="videos">
            <VideoLibraryTab />
          </TabsContent>
          <TabsContent value="inbox">
            <InboundTestTab />
          </TabsContent>
        </Card>
      </Tabs>
    </div>
  )
}
