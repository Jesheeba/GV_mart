import { useState } from "react"
import { useTranslation } from "react-i18next"
import { Loader2, Megaphone, Plus, Trash2 } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Card } from "@/components/ui/card"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { DataTable, type DataTableColumn } from "@/components/shared/DataTable"
import { StatusDot, type StatusTone } from "@/components/shared/StatusDot"
import { useProfile } from "@/hooks/useProfile"
import { useCampaigns, useCreateCampaign, useDeleteCampaign, useUpdateCampaignStatus } from "@/hooks/useSystemPages"
import type { CampaignRow, CampaignStatus } from "@/services/systemPages"
import { createCampaignSchema } from "@/lib/validation/systemPages"

const STATUS_TONE: Record<CampaignStatus, StatusTone> = { draft: "neutral", active: "success", completed: "info" }
const CHANNEL_OPTIONS = ["whatsapp", "sms", "email", "call"]

const textareaClass =
  "w-full min-w-0 rounded-xl border border-input bg-surface px-3.5 py-2.5 text-sm text-text transition-colors outline-none placeholder:text-text-muted focus-visible:border-ring focus-visible:ring-3 focus-visible:ring-ring/30"

export function CampaignsPage() {
  const { t } = useTranslation()
  const { data: profile } = useProfile()
  const { data, isLoading, isError, refetch } = useCampaigns(profile?.org_id)
  const createCampaign = useCreateCampaign()
  const updateStatus = useUpdateCampaignStatus()
  const deleteCampaign = useDeleteCampaign()

  const [formOpen, setFormOpen] = useState(false)
  const [name, setName] = useState("")
  const [channel, setChannel] = useState(CHANNEL_OPTIONS[0])
  const [targetSegment, setTargetSegment] = useState("")
  const [startDate, setStartDate] = useState("")
  const [endDate, setEndDate] = useState("")
  const [message, setMessage] = useState("")

  const parsed = createCampaignSchema.safeParse({ name, channel, targetSegment, startDate, endDate, message })

  function resetForm() {
    setName("")
    setChannel(CHANNEL_OPTIONS[0])
    setTargetSegment("")
    setStartDate("")
    setEndDate("")
    setMessage("")
    setFormOpen(false)
  }

  function handleCreate() {
    if (!parsed.success || !profile) return
    createCampaign.mutate(
      {
        orgId: profile.org_id,
        name: name.trim(),
        channel,
        targetSegment: targetSegment.trim() || null,
        startDate: startDate || null,
        endDate: endDate || null,
        message: message.trim() || null,
      },
      { onSuccess: resetForm }
    )
  }

  const columns: DataTableColumn<CampaignRow>[] = [
    { key: "name", header: t("campaigns.table.name"), render: (c) => <span className="font-medium text-text">{c.name}</span> },
    { key: "channel", header: t("campaigns.table.channel"), render: (c) => (CHANNEL_OPTIONS.includes(c.channel) ? t(`campaigns.channel.${c.channel}`) : c.channel) },
    { key: "segment", header: t("campaigns.table.segment"), render: (c) => c.target_segment ?? "—" },
    { key: "dates", header: t("campaigns.table.dates"), render: (c) => [c.start_date, c.end_date].filter(Boolean).join(" → ") || "—" },
    { key: "status", header: t("campaigns.table.status"), render: (c) => <StatusDot tone={STATUS_TONE[c.status as CampaignStatus]} label={t(`campaigns.status.${c.status}`)} /> },
    {
      key: "actions",
      header: "",
      className: "text-right",
      render: (c) => (
        <div className="flex items-center justify-end gap-1.5">
          {c.status === "draft" ? (
            <Button size="xs" variant="outline" onClick={() => updateStatus.mutate({ id: c.id, status: "active" })}>
              {t("campaigns.actions.activate")}
            </Button>
          ) : null}
          {c.status === "active" ? (
            <Button size="xs" variant="outline" onClick={() => updateStatus.mutate({ id: c.id, status: "completed" })}>
              {t("campaigns.actions.complete")}
            </Button>
          ) : null}
          <Button size="icon-xs" variant="ghost" title={t("common.delete")} onClick={() => deleteCampaign.mutate(c.id)}>
            <Trash2 className="size-3.5 text-danger" />
          </Button>
        </div>
      ),
    },
  ]

  return (
    <div className="space-y-4 pt-2">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <div>
          <h1 className="text-2xl font-bold text-text">{t("nav.campaigns")}</h1>
          <p className="text-sm text-text-muted">{t("campaigns.subtitle")}</p>
        </div>
        <Button type="button" onClick={() => setFormOpen((v) => !v)}>
          <Plus className="size-3.5" />
          {t("campaigns.newCampaign")}
        </Button>
      </div>

      <p className="rounded-xl bg-surface-alt px-3 py-2 text-xs text-text-muted">{t("campaigns.noSendIntegrationNote")}</p>

      {formOpen ? (
        <Card size="default" className="gap-3 px-5">
          <div className="grid grid-cols-1 gap-3 sm:grid-cols-2">
            <div className="space-y-1">
              <Label htmlFor="c-name">{t("campaigns.form.name")}</Label>
              <Input id="c-name" value={name} onChange={(e) => setName(e.target.value)} />
            </div>
            <div className="space-y-1">
              <Label htmlFor="c-channel">{t("campaigns.form.channel")}</Label>
              <select
                id="c-channel"
                value={channel}
                onChange={(e) => setChannel(e.target.value)}
                className="h-11 w-full rounded-xl border border-border bg-surface px-3 text-sm text-text outline-none"
              >
                {CHANNEL_OPTIONS.map((c) => (
                  <option key={c} value={c}>
                    {t(`campaigns.channel.${c}`)}
                  </option>
                ))}
              </select>
            </div>
            <div className="space-y-1">
              <Label htmlFor="c-segment">{t("campaigns.form.segment")}</Label>
              <Input id="c-segment" placeholder={t("campaigns.form.segmentPlaceholder")} value={targetSegment} onChange={(e) => setTargetSegment(e.target.value)} />
            </div>
            <div className="grid grid-cols-2 gap-3">
              <div className="space-y-1">
                <Label htmlFor="c-start">{t("campaigns.form.startDate")}</Label>
                <Input id="c-start" type="date" value={startDate} onChange={(e) => setStartDate(e.target.value)} />
              </div>
              <div className="space-y-1">
                <Label htmlFor="c-end">{t("campaigns.form.endDate")}</Label>
                <Input id="c-end" type="date" value={endDate} onChange={(e) => setEndDate(e.target.value)} />
              </div>
            </div>
            <div className="space-y-1 sm:col-span-2">
              <Label htmlFor="c-message">{t("campaigns.form.message")}</Label>
              <textarea id="c-message" rows={3} value={message} onChange={(e) => setMessage(e.target.value)} className={textareaClass} />
            </div>
          </div>
          <div className="flex justify-end gap-2">
            <Button type="button" variant="ghost" size="sm" onClick={resetForm}>
              {t("common.cancel")}
            </Button>
            <Button type="button" size="sm" disabled={!parsed.success || createCampaign.isPending} onClick={handleCreate}>
              {createCampaign.isPending ? <Loader2 className="size-3.5 animate-spin" /> : t("common.save")}
            </Button>
          </div>
        </Card>
      ) : null}

      {isError ? (
        <Card className="items-center gap-2 py-8 text-center">
          <p className="text-sm text-danger">{t("campaigns.loadFailed")}</p>
          <Button type="button" variant="outline" size="sm" onClick={() => refetch()}>
            {t("common.retry")}
          </Button>
        </Card>
      ) : !isLoading && (data?.length ?? 0) === 0 ? (
        <Card className="items-center gap-2 py-10 text-center">
          <Megaphone className="size-6 text-text-muted" />
          <p className="text-sm text-text-muted">{t("campaigns.empty")}</p>
        </Card>
      ) : (
        <DataTable columns={columns} rows={data ?? []} rowKey={(c) => c.id} loading={isLoading} emptyMessage={t("campaigns.empty")} />
      )}
    </div>
  )
}
