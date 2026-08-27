import { useTranslation } from "react-i18next"
import { Ban, Loader2, MessageSquareOff, MessageSquareText, Sparkles } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Card } from "@/components/ui/card"
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs"
import { useSettings, useUpdateSettings } from "@/hooks/useMasters"
import { useProfile } from "@/hooks/useProfile"
import { cn } from "@/lib/utils"
import { AutomationFlowsTab } from "./AutomationFlowsTab"
import { VideoLibraryTab } from "./VideoLibraryTab"
import { InboundTestTab } from "./InboundTestTab"
import { ConversationsTab } from "./ConversationsTab"
import { TemplatesTab } from "./TemplatesTab"
import { FailedSendsTab } from "./FailedSendsTab"
import { AutomationJobsTab } from "./AutomationJobsTab"

/** Prominently placed, not buried in a tab — visible and one click,
 * regardless of which tab is open, per the plan's "bot kill switch,
 * prominently placed" requirement. Checked FIRST thing in the
 * whatsapp-webhook Edge Function (settings.whatsapp_bot_enabled). */
function BotKillSwitch() {
  const { t } = useTranslation()
  const { data: profile } = useProfile()
  const orgId = profile?.org_id
  const { data: settings, isLoading } = useSettings(orgId)
  const updateMut = useUpdateSettings(orgId)

  if (isLoading || !settings) return <div className="h-9 w-36 animate-pulse rounded-full bg-surface-alt" />

  const enabled = settings.whatsapp_bot_enabled
  return (
    <Button
      size="sm"
      variant="outline"
      className={cn("border-transparent font-bold", enabled ? "bg-success/10 text-success hover:bg-success/20" : "bg-danger/10 text-danger hover:bg-danger/20")}
      disabled={updateMut.isPending}
      onClick={() => updateMut.mutate({ whatsapp_bot_enabled: !enabled })}
    >
      {updateMut.isPending ? <Loader2 className="size-3.5 animate-spin" /> : enabled ? <MessageSquareText className="size-3.5" /> : <MessageSquareOff className="size-3.5" />}
      {enabled ? t("automation.killSwitch.on") : t("automation.killSwitch.off")}
    </Button>
  )
}

/** Independent of BotKillSwitch above — turning this off silences only the
 * AI/CRM Answer Layer (settings.wa_answer_layer_enabled), not the rest of
 * the bot; journeys keep working. Checked FIRST thing in
 * answerCustomerQuestion() (_shared/whatsapp-answer-layer.ts), no redeploy
 * needed to flip it. Placed alongside the bot switch, not buried in a tab,
 * for the early-rollout daily-review period. */
function AnswerLayerKillSwitch() {
  const { t } = useTranslation()
  const { data: profile } = useProfile()
  const orgId = profile?.org_id
  const { data: settings, isLoading } = useSettings(orgId)
  const updateMut = useUpdateSettings(orgId)

  if (isLoading || !settings) return <div className="h-9 w-40 animate-pulse rounded-full bg-surface-alt" />

  const enabled = settings.wa_answer_layer_enabled
  return (
    <Button
      size="sm"
      variant="outline"
      className={cn("border-transparent font-bold", enabled ? "bg-success/10 text-success hover:bg-success/20" : "bg-danger/10 text-danger hover:bg-danger/20")}
      disabled={updateMut.isPending}
      onClick={() => updateMut.mutate({ wa_answer_layer_enabled: !enabled })}
    >
      {updateMut.isPending ? <Loader2 className="size-3.5 animate-spin" /> : enabled ? <Sparkles className="size-3.5" /> : <Ban className="size-3.5" />}
      {enabled ? t("automation.answerLayerKillSwitch.on") : t("automation.answerLayerKillSwitch.off")}
    </Button>
  )
}

export function AutomationPage() {
  const { t } = useTranslation()

  return (
    <div className="space-y-4 pt-2">
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <h1 className="text-2xl font-bold text-text">{t("nav.automation")}</h1>
          <p className="text-sm text-text-muted">{t("automation.subtitle")}</p>
        </div>
        <div className="flex flex-wrap items-center gap-2">
          <BotKillSwitch />
          <AnswerLayerKillSwitch />
        </div>
      </div>

      <Tabs defaultValue="flows">
        <TabsList>
          <TabsTrigger value="flows">{t("automation.tabs.flows")}</TabsTrigger>
          <TabsTrigger value="videos">{t("automation.tabs.videos")}</TabsTrigger>
          <TabsTrigger value="inbox">{t("automation.tabs.inbox")}</TabsTrigger>
          <TabsTrigger value="conversations">{t("automation.tabs.conversations")}</TabsTrigger>
          <TabsTrigger value="templates">{t("automation.tabs.templates")}</TabsTrigger>
          <TabsTrigger value="failedSends">{t("automation.tabs.failedSends")}</TabsTrigger>
          <TabsTrigger value="jobs">{t("automation.tabs.jobs")}</TabsTrigger>
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
          <TabsContent value="conversations">
            <ConversationsTab />
          </TabsContent>
          <TabsContent value="templates">
            <TemplatesTab />
          </TabsContent>
          <TabsContent value="failedSends">
            <FailedSendsTab />
          </TabsContent>
          <TabsContent value="jobs">
            <AutomationJobsTab />
          </TabsContent>
        </Card>
      </Tabs>
    </div>
  )
}
