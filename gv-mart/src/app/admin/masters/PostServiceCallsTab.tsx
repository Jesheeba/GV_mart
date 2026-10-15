import { useEffect, useState } from "react"
import { useTranslation } from "react-i18next"
import { Loader2 } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Card } from "@/components/ui/card"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { useToast } from "@/components/ui/toast-context"
import { EntityCrudTable, type CrudFieldDef } from "@/components/shared/EntityCrudTable"
import { StatusDot } from "@/components/shared/StatusDot"
import { postServiceOutcomesHooks, useSettings, useUpdateSettings } from "@/hooks/useMasters"
import { useLeadAssignees } from "@/hooks/useLeadFollowups"
import { useProfile } from "@/hooks/useProfile"
import { postServiceOutcomeInUse, type PostServiceOutcomeRow } from "@/services/masters"
import { POST_SERVICE_TICKET_TYPES } from "@/services/postServiceFollowups"
import { leadSourceKeyFromLabel } from "@/lib/lead-sources"
import { FollowupQuestionsSection } from "./FollowupQuestionsSection"
import type { UserRole } from "@/lib/roles"

/**
 * Masters > Post-service calls (batch-17 item 13): the master's switch, delay, recipient and ticket types for the
 * "call the customer after the job" follow-up, plus the editable list of call outcomes. The switch ships OFF.
 */
export function PostServiceCallsTab() {
  return (
    <div className="space-y-5">
      <SettingsCard />
      <OutcomesList />
      <FollowupQuestionsSection />
    </div>
  )
}

function SettingsCard() {
  const { t } = useTranslation()
  const { toast } = useToast()
  const { data: profile } = useProfile()
  const orgId = profile?.org_id
  const settings = useSettings(orgId)
  const update = useUpdateSettings(orgId)
  const assignees = useLeadAssignees(orgId, profile?.role as UserRole | undefined).data ?? []

  const [enabled, setEnabled] = useState(false)
  const [days, setDays] = useState("2")
  const [assignee, setAssignee] = useState("")
  const [types, setTypes] = useState<string[]>([])
  const [dedupe, setDedupe] = useState("0")

  useEffect(() => {
    const s = settings.data
    if (!s) return
    setEnabled(s.post_service_followup_enabled)
    setDays(String(s.post_service_followup_days))
    setAssignee(s.post_service_followup_assignee ?? "")
    setTypes(s.post_service_ticket_types)
    setDedupe(String(s.post_service_dedupe_days))
  }, [settings.data])

  const daysN = Number(days)
  const dedupeN = Number(dedupe)
  const valid = Number.isInteger(daysN) && daysN >= 0 && daysN <= 60 && Number.isInteger(dedupeN) && dedupeN >= 0 && dedupeN <= 60 && types.length > 0

  function save() {
    update.mutate(
      {
        post_service_followup_enabled: enabled,
        post_service_followup_days: daysN,
        post_service_followup_assignee: assignee || null,
        post_service_ticket_types: types,
        post_service_dedupe_days: dedupeN,
      },
      {
        onSuccess: () => toast.success(t("masters.postService.saved")),
        onError: (e) => toast.error(e instanceof Error && e.message ? e.message : t("common.actionFailed")),
      }
    )
  }

  if (settings.isLoading || !settings.data) return <Card className="px-5 py-4 text-sm text-text-muted">{t("common.loading")}</Card>

  return (
    <Card className="gap-3.5 px-5">
      <div>
        <h3 className="text-sm font-semibold text-text">{t("masters.postService.title")}</h3>
        <p className="text-xs text-text-muted">{t("masters.postService.hint")}</p>
      </div>

      <label className="flex items-center gap-2.5 rounded-xl border border-border bg-surface-alt px-3.5 py-2.5 text-sm text-text">
        <input type="checkbox" className="size-4 accent-accent" checked={enabled} onChange={(e) => setEnabled(e.target.checked)} />
        <span className="flex-1">
          <span className="block font-medium">{enabled ? t("masters.postService.on") : t("masters.postService.off")}</span>
          <span className="block text-xs text-text-muted">{t("masters.postService.switchHint")}</span>
        </span>
      </label>

      <div className="grid grid-cols-1 gap-3 sm:grid-cols-2">
        <div className="space-y-1.5">
          <Label htmlFor="ps-days">{t("masters.postService.days")}</Label>
          <Input id="ps-days" type="number" min={0} max={60} value={days} onChange={(e) => setDays(e.target.value)} />
          <p className="text-xs text-text-muted">{t("masters.postService.daysHint")}</p>
        </div>
        <div className="space-y-1.5">
          <Label htmlFor="ps-assignee">{t("masters.postService.recipient")}</Label>
          <select
            id="ps-assignee"
            value={assignee}
            onChange={(e) => setAssignee(e.target.value)}
            className="h-10 w-full rounded-xl border border-border bg-surface px-3 text-sm text-text outline-none"
          >
            <option value="">{t("masters.postService.allSales")}</option>
            {assignees.map((a) => (
              <option key={a.id} value={a.id}>
                {a.full_name}
              </option>
            ))}
          </select>
          <p className="text-xs text-text-muted">{t("masters.postService.recipientHint")}</p>
        </div>
        <div className="space-y-1.5">
          <Label htmlFor="ps-dedupe">{t("masters.postService.dedupe")}</Label>
          <Input id="ps-dedupe" type="number" min={0} max={60} value={dedupe} onChange={(e) => setDedupe(e.target.value)} />
          <p className="text-xs text-text-muted">{t("masters.postService.dedupeHint")}</p>
        </div>
      </div>

      <fieldset className="space-y-1.5">
        <legend className="text-sm font-medium text-text">{t("masters.postService.types")}</legend>
        <div className="flex flex-wrap gap-2">
          {POST_SERVICE_TICKET_TYPES.map((ty) => (
            <label key={ty} className="flex items-center gap-1.5 rounded-full border border-border bg-surface px-3 py-1.5 text-xs font-semibold text-text">
              <input
                type="checkbox"
                className="size-3.5 accent-accent"
                checked={types.includes(ty)}
                onChange={(e) => setTypes((cur) => (e.target.checked ? [...cur, ty] : cur.filter((x) => x !== ty)))}
              />
              {t(`service.type.${ty}`)}
            </label>
          ))}
        </div>
        <p className="text-xs text-text-muted">{t("masters.postService.typesHint")}</p>
      </fieldset>

      <div className="flex justify-end">
        <Button onClick={save} disabled={!valid || update.isPending}>
          {update.isPending ? <Loader2 className="size-4 animate-spin" /> : t("common.save")}
        </Button>
      </div>
    </Card>
  )
}

function OutcomesList() {
  const { t, i18n } = useTranslation()
  const { data: profile } = useProfile()
  const orgId = profile?.org_id
  const { data: rows, isLoading, isError, refetch } = postServiceOutcomesHooks.useList(orgId)
  const createMut = postServiceOutcomesHooks.useCreate()
  const updateMut = postServiceOutcomesHooks.useUpdate()
  const deleteMut = postServiceOutcomesHooks.useDelete()
  const existing = rows ?? []
  const yesNo = [
    { value: "false", label: t("masters.postService.no") },
    { value: "true", label: t("masters.postService.yes") },
  ]
  const label = (r: PostServiceOutcomeRow) => (i18n.language.startsWith("ta") && r.label_ta ? r.label_ta : r.label_en)

  const fields: CrudFieldDef[] = [
    { key: "label_en", label: t("masters.postService.outcomeEn"), type: "text", required: true },
    { key: "label_ta", label: t("masters.postService.outcomeTa"), type: "text", required: true },
    { key: "retry", label: t("masters.postService.retry"), type: "select", options: yesNo },
    { key: "alert", label: t("masters.postService.alert"), type: "select", options: yesNo },
    {
      key: "is_active",
      label: t("masters.leadKinds.status"),
      type: "select",
      options: [
        { value: "true", label: t("masters.leadKinds.active") },
        { value: "false", label: t("masters.leadKinds.inactive") },
      ],
    },
  ]

  return (
    <div className="space-y-3">
      <div className="px-1">
        <h3 className="text-sm font-semibold text-text">{t("masters.postService.outcomesTitle")}</h3>
        <p className="text-xs text-text-muted">{t("masters.postService.outcomesHint")}</p>
      </div>
      <EntityCrudTable<PostServiceOutcomeRow>
        fields={fields}
        rows={existing}
        getId={(r) => r.id}
        loading={isLoading}
        error={isError ? t("masters.loadFailed") : null}
        onRetry={() => refetch()}
        isMutating={createMut.isPending || updateMut.isPending}
        addLabel={t("masters.postService.addOutcome")}
        emptyMessage={t("masters.postService.noOutcomes")}
        toFormValues={(r) => ({ label_en: r.label_en, label_ta: r.label_ta, retry: String(r.retry), alert: String(r.alert), is_active: String(r.is_active) })}
        columns={[
          { key: "label", header: t("masters.postService.outcomeEn"), render: (r) => <span className="font-medium text-text">{label(r)}</span> },
          { key: "retry", header: t("masters.postService.retry"), render: (r) => (r.retry ? t("masters.postService.yes") : "—") },
          { key: "alert", header: t("masters.postService.alert"), render: (r) => (r.alert ? t("masters.postService.yes") : "—") },
          { key: "type", header: t("masters.leadKinds.type"), render: (r) => (r.is_system ? t("masters.leadKinds.builtIn") : t("masters.leadKinds.custom")) },
          {
            key: "status",
            header: t("masters.leadKinds.status"),
            render: (r) => <StatusDot tone={r.is_active ? "success" : "neutral"} label={r.is_active ? t("masters.leadKinds.active") : t("masters.leadKinds.inactive")} />,
          },
        ]}
        onCreate={async (v) => {
          const code = leadSourceKeyFromLabel(v.label_en)
          if (!code) throw new Error(t("masters.postService.invalidLabel"))
          if (existing.some((r) => r.code === code)) throw new Error(t("masters.postService.duplicate"))
          const sort = existing.reduce((m, r) => Math.max(m, r.sort_order), 0) + 1
          return createMut.mutateAsync({
            org_id: orgId!,
            code,
            label_en: v.label_en.trim(),
            label_ta: v.label_ta.trim(),
            retry: v.retry === "true",
            alert: v.alert === "true",
            is_active: v.is_active !== "false",
            sort_order: sort,
          })
        }}
        onUpdate={(id, v) =>
          updateMut.mutateAsync({
            id,
            patch: { label_en: v.label_en.trim(), label_ta: v.label_ta.trim(), retry: v.retry === "true", alert: v.alert === "true", is_active: v.is_active !== "false" },
          })
        }
        onDelete={(id) => deleteMut.mutateAsync(id)}
        checkCanDelete={async (id) => {
          const row = existing.find((r) => r.id === id)
          if (!row || row.is_system) return false
          return !(await postServiceOutcomeInUse(id))
        }}
        cannotDeleteMessage={t("masters.postService.cannotDelete")}
      />
    </div>
  )
}
