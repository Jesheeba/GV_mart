import { zodResolver } from "@hookform/resolvers/zod"
import { useForm } from "react-hook-form"
import { useTranslation } from "react-i18next"
import { Loader2, Send } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Card } from "@/components/ui/card"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { DataTable, type DataTableColumn } from "@/components/shared/DataTable"
import { useProfile } from "@/hooks/useProfile"
import { useSimulateInboundWhatsapp, useWhatsappOutbox } from "@/hooks/useAutomation"
import { simulateInboundSchema, type SimulateInboundInput } from "@/lib/validation/automation"
import type { WhatsappOutboxRow } from "@/services/automation"

/** ADM-23's "/api/whatsapp/webhook" has no real HTTP route to host in this
 * Vite SPA — this panel calls the same `simulate_inbound_whatsapp` RPC a
 * real Edge Function webhook would call, so admins can verify flow matching
 * end-to-end without live WhatsApp credentials. */
export function InboundTestTab() {
  const { t } = useTranslation()
  const { data: profile } = useProfile()
  const orgId = profile?.org_id

  const outbox = useWhatsappOutbox(orgId)
  const simulate = useSimulateInboundWhatsapp()

  const form = useForm<SimulateInboundInput>({
    resolver: zodResolver(simulateInboundSchema),
    mode: "onChange",
    defaultValues: { fromMobile: "9840000000", body: "" },
  })

  async function onSubmit(values: SimulateInboundInput) {
    await simulate.mutateAsync({ orgId: orgId!, fromMobile: values.fromMobile, body: values.body })
    form.setValue("body", "")
  }

  const columns: DataTableColumn<WhatsappOutboxRow>[] = [
    { key: "time", header: t("automation.inbox.time"), render: (r) => new Date(r.created_at).toLocaleString("en-IN") },
    {
      key: "direction",
      header: t("automation.inbox.direction"),
      render: (r) => <span className={r.direction === "inbound" ? "text-info" : "text-success"}>{t(`automation.inbox.directions.${r.direction}`)}</span>,
    },
    { key: "to", header: t("automation.inbox.contact"), render: (r) => r.to_mobile ?? "—" },
    { key: "milestone", header: t("automation.inbox.milestone"), render: (r) => r.milestone ?? "—" },
    { key: "template", header: t("automation.inbox.template"), render: (r) => r.template },
    { key: "status", header: t("automation.inbox.status"), render: (r) => r.status },
  ]

  return (
    <div className="space-y-4">
      <Card className="gap-3">
        <h2 className="text-sm font-semibold text-text">{t("automation.inbox.testTitle")}</h2>
        <p className="text-xs text-text-muted">{t("automation.inbox.testHint")}</p>
        <div className="grid grid-cols-1 gap-3 sm:grid-cols-3">
          <div className="space-y-1.5">
            <Label>{t("automation.inbox.fromMobile")}</Label>
            <Input {...form.register("fromMobile")} />
          </div>
          <div className="space-y-1.5 sm:col-span-2">
            <Label>{t("automation.inbox.body")}</Label>
            <Input placeholder={t("automation.inbox.bodyPlaceholder")} {...form.register("body")} />
          </div>
        </div>
        {simulate.error ? <p className="rounded-xl bg-danger/10 px-3.5 py-2.5 text-sm text-danger">{(simulate.error as Error).message}</p> : null}
        <div className="flex justify-end">
          <Button onClick={form.handleSubmit(onSubmit)} disabled={simulate.isPending}>
            {simulate.isPending ? <Loader2 className="size-4 animate-spin" /> : <Send className="size-4" />}
            {t("automation.inbox.send")}
          </Button>
        </div>
      </Card>

      <DataTable
        columns={columns}
        rows={outbox.data ?? []}
        rowKey={(r) => r.id}
        loading={outbox.isLoading}
        error={outbox.isError ? t("automation.loadFailed") : null}
        onRetry={() => outbox.refetch()}
        emptyMessage={t("automation.inbox.empty")}
      />
    </div>
  )
}
