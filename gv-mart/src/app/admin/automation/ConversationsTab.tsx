import { useState } from "react"
import { useTranslation } from "react-i18next"
import { X } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Card } from "@/components/ui/card"
import { Badge } from "@/components/ui/badge"
import { Skeleton } from "@/components/ui/skeleton"
import { DataTable, type DataTableColumn } from "@/components/shared/DataTable"
import { useWhatsappConversations, useWhatsappTranscript } from "@/hooks/useAutomation"
import { useProfile } from "@/hooks/useProfile"
import { cn } from "@/lib/utils"
import type { WhatsappConversationListItem } from "@/services/automation"

const STATUS_VARIANT: Record<string, "success" | "warning" | "danger" | "secondary"> = {
  active: "success",
  completed: "secondary",
  expired: "warning",
  handed_off: "danger",
}

function TranscriptPanel({ orgId, phone, onClose }: { orgId: string; phone: string; onClose: () => void }) {
  const { t } = useTranslation()
  const { data: messages, isLoading } = useWhatsappTranscript(orgId, phone)

  return (
    <Card className="gap-3 px-5">
      <div className="flex items-center justify-between">
        <h3 className="text-sm font-semibold text-text">{t("automation.conversations.transcriptTitle", { phone })}</h3>
        <Button size="icon-xs" variant="ghost" onClick={onClose}>
          <X className="size-4" />
        </Button>
      </div>
      {isLoading ? (
        <Skeleton className="h-24 w-full" />
      ) : (messages ?? []).length === 0 ? (
        <p className="py-6 text-center text-sm text-text-muted">{t("automation.conversations.transcriptEmpty")}</p>
      ) : (
        <div className="flex max-h-100 flex-col gap-2 overflow-y-auto">
          {(messages ?? []).map((m) => (
            <div key={m.id} className={cn("max-w-[80%] rounded-2xl px-3.5 py-2 text-sm", m.direction === "inbound" ? "self-start bg-surface-alt text-text" : "self-end bg-accent/15 text-text")}>
              <p>{(m.payload as { body?: string })?.body ?? m.template}</p>
              <p className="mt-1 text-[10px] text-text-muted">{new Date(m.created_at).toLocaleString("en-IN")}</p>
            </div>
          ))}
        </div>
      )}
    </Card>
  )
}

/** List + transcript, per the plan's ops-surface spec. Selecting a row
 * shows that conversation's full whatsapp_outbox history (both directions,
 * chronological) — the same table Failed Sends filters differently and
 * CustomerDetailPage's WhatsApp tab reads per-customer. */
export function ConversationsTab() {
  const { t } = useTranslation()
  const { data: profile } = useProfile()
  const orgId = profile?.org_id

  const { data: rows, isLoading, isError, refetch } = useWhatsappConversations(orgId)
  const [selectedPhone, setSelectedPhone] = useState<string | null>(null)

  const columns: DataTableColumn<WhatsappConversationListItem>[] = [
    { key: "phone", header: t("automation.conversations.phone"), render: (r) => r.phone },
    { key: "customer", header: t("automation.conversations.customer"), render: (r) => r.customers?.name ?? t("automation.conversations.unknownCustomer") },
    { key: "journey", header: t("automation.conversations.journey"), render: (r) => r.journey ?? "—" },
    { key: "step", header: t("automation.conversations.step"), render: (r) => r.step ?? "—" },
    { key: "status", header: t("automation.conversations.status"), render: (r) => <Badge variant={STATUS_VARIANT[r.status] ?? "secondary"}>{t(`automation.conversations.statuses.${r.status}`)}</Badge> },
    { key: "lastMessage", header: t("automation.conversations.lastMessage"), render: (r) => new Date(r.last_message_at).toLocaleString("en-IN") },
  ]

  return (
    <div className="space-y-3">
      <DataTable
        columns={columns}
        rows={rows ?? []}
        rowKey={(r) => r.id}
        loading={isLoading}
        error={isError ? t("automation.loadFailed") : null}
        onRetry={() => refetch()}
        emptyMessage={t("automation.conversations.empty")}
        onRowClick={(r) => setSelectedPhone(r.phone)}
      />
      {selectedPhone && orgId ? <TranscriptPanel orgId={orgId} phone={selectedPhone} onClose={() => setSelectedPhone(null)} /> : null}
    </div>
  )
}
