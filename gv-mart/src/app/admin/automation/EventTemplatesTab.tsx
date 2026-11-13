import { useTranslation } from "react-i18next"
import { Loader2, MessageSquareOff, MessageSquareText } from "lucide-react"
import { Button } from "@/components/ui/button"
import { useProfile } from "@/hooks/useProfile"
import { useSetWhatsappEventTemplateActive, useWhatsappEventTemplates } from "@/hooks/useAutomation"
import { cn } from "@/lib/utils"
import type { WhatsappEventTemplateRow } from "@/services/automation"

/** Per-event on/off for the v2 (Wasi-approved gvm_* template) mapping — distinct from the v1
 * TemplatesTab above, which edits the older free-text whatsapp_templates table. is_active already
 * exists on whatsapp_event_templates and is already respected by findApprovedMapping
 * (_shared/whatsapp.ts) — this is just the first UI to flip it, reading whatever rows exist rather
 * than hardcoding the event list, so it stays correct as more events get wired later. */
function EventToggle({ row }: { row: WhatsappEventTemplateRow }) {
  const mut = useSetWhatsappEventTemplateActive()
  const enabled = row.is_active
  return (
    <Button
      size="sm"
      variant="outline"
      className={cn("border-transparent font-bold", enabled ? "bg-success/10 text-success hover:bg-success/20" : "bg-danger/10 text-danger hover:bg-danger/20")}
      disabled={mut.isPending}
      onClick={() => mut.mutate({ id: row.id, isActive: !enabled })}
    >
      {mut.isPending ? <Loader2 className="size-3.5 animate-spin" /> : enabled ? <MessageSquareText className="size-3.5" /> : <MessageSquareOff className="size-3.5" />}
    </Button>
  )
}

export function EventTemplatesTab() {
  const { t } = useTranslation()
  const { data: profile } = useProfile()
  const orgId = profile?.org_id

  const { data: rows, isLoading, isError } = useWhatsappEventTemplates(orgId)

  return (
    <div className="space-y-3">
      <p className="text-xs text-text-muted">{t("automation.eventTemplates.hint")}</p>
      {isLoading ? (
        <Loader2 className="size-5 animate-spin text-text-muted" />
      ) : isError ? (
        <p className="text-sm text-danger">{t("automation.eventTemplates.loadFailed")}</p>
      ) : !rows?.length ? (
        <p className="text-sm text-text-muted">{t("automation.eventTemplates.empty")}</p>
      ) : (
        <table className="w-full text-sm">
          <thead>
            <tr className="border-b border-border text-left text-xs text-text-muted">
              <th className="py-2 font-medium">{t("automation.eventTemplates.event")}</th>
              <th className="py-2 font-medium">{t("automation.eventTemplates.template")}</th>
              <th className="py-2 font-medium">{t("automation.eventTemplates.status")}</th>
            </tr>
          </thead>
          <tbody>
            {rows.map((r) => (
              <tr key={r.id} className="border-b border-border/50">
                <td className="py-2">{t(`automation.eventTemplates.eventLabels.${r.event_key}`, { defaultValue: r.event_key })}</td>
                <td className="py-2 font-mono text-xs">{r.wasi_template_name}</td>
                <td className="py-2">
                  <EventToggle row={r} />
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      )}
    </div>
  )
}
