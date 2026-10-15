import { useMemo, useState } from "react"
import { useTranslation } from "react-i18next"
import { Card } from "@/components/ui/card"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { useToast } from "@/components/ui/toast-context"
import { EntityCrudTable, type CrudFieldDef } from "@/components/shared/EntityCrudTable"
import { StatusDot } from "@/components/shared/StatusDot"
import { useProfile } from "@/hooks/useProfile"
import {
  useCreateFollowupQuestion,
  useFollowupAnswersReport,
  useFollowupQuestionList,
  useFollowupQuestionTypeLinks,
  useSetFollowupQuestionTypeLink,
  useUpdateFollowupQuestion,
} from "@/hooks/useFollowupQuestions"
import type { FollowupQuestionRow } from "@/services/followupQuestions"
import { FOLLOWUP_TICKET_TYPES, choicesToLines, parseChoiceLines, pickText, type AnswerType } from "@/lib/followup-questions"
import { cn } from "@/lib/utils"

const ANSWER_TYPES: AnswerType[] = ["yes_no", "choice", "rating", "text"]

/**
 * Masters > Post-service calls > Questions: the questions asked on a post-service call, plus a read-only answers report.
 * Questions are never deleted (deactivate instead) so old answers keep their wording. Nothing here touches ratings or reviews.
 */
export function FollowupQuestionsSection() {
  return (
    <div className="space-y-5">
      <QuestionsList />
      <AnswersReport />
    </div>
  )
}

function QuestionsList() {
  const { t, i18n } = useTranslation()
  const { toast } = useToast()
  const { data: profile } = useProfile()
  const orgId = profile?.org_id
  const list = useFollowupQuestionList(orgId)
  const links = useFollowupQuestionTypeLinks(orgId)
  const createMut = useCreateFollowupQuestion()
  const updateMut = useUpdateFollowupQuestion()
  const linkMut = useSetFollowupQuestionTypeLink()
  const rows = list.data ?? []
  const yesNo = [
    { value: "true", label: t("common.yes") },
    { value: "false", label: t("common.no") },
  ]

  const fields: CrudFieldDef[] = [
    { key: "text_en", label: t("masters.followupQuestions.textEn"), type: "text", required: true },
    { key: "text_ta", label: t("masters.followupQuestions.textTa"), type: "text" },
    { key: "answer_type", label: t("masters.followupQuestions.answerType"), type: "select", options: ANSWER_TYPES.map((a) => ({ value: a, label: t(`masters.followupQuestions.types.${a}`) })) },
    { key: "choices", label: t("masters.followupQuestions.choices"), type: "textarea", placeholder: t("masters.followupQuestions.choicesPlaceholder") },
    { key: "is_required", label: t("masters.followupQuestions.required"), type: "select", options: yesNo },
    { key: "is_active", label: t("masters.leadKinds.status"), type: "select", options: [{ value: "true", label: t("masters.leadKinds.active") }, { value: "false", label: t("masters.leadKinds.inactive") }] },
    { key: "sort_order", label: t("masters.followupQuestions.order"), type: "number" },
  ]

  function choicesFor(v: Record<string, string>) {
    if (v.answer_type !== "choice") return null
    try {
      return parseChoiceLines(v.choices ?? "")
    } catch (e) {
      throw new Error(t(`masters.followupQuestions.errors.${e instanceof Error ? e.message.replace(".", "_") : "choices_count"}`))
    }
  }

  const linkedTypes = useMemo(() => {
    const m = new Map<string, Set<string>>()
    for (const l of links.data ?? []) {
      if (!m.has(l.question_id)) m.set(l.question_id, new Set())
      m.get(l.question_id)!.add(l.ticket_type)
    }
    return m
  }, [links.data])

  return (
    <div className="space-y-3">
      <div className="px-1">
        <h3 className="text-sm font-semibold text-text">{t("masters.followupQuestions.title")}</h3>
        <p className="text-xs text-text-muted">{t("masters.followupQuestions.hint")}</p>
      </div>
      <EntityCrudTable<FollowupQuestionRow>
        fields={fields}
        rows={rows}
        getId={(r) => r.id}
        loading={list.isLoading}
        error={list.isError ? t("masters.loadFailed") : null}
        onRetry={() => list.refetch()}
        isMutating={createMut.isPending || updateMut.isPending}
        addLabel={t("masters.followupQuestions.add")}
        emptyMessage={t("masters.followupQuestions.empty")}
        toFormValues={(r) => ({
          text_en: r.text_en,
          text_ta: r.text_ta,
          answer_type: r.answer_type,
          choices: choicesToLines(r.choices),
          is_required: String(r.is_required),
          is_active: String(r.is_active),
          sort_order: String(r.sort_order),
        })}
        columns={[
          {
            key: "text",
            header: t("masters.followupQuestions.textEn"),
            render: (r) => <span className="font-medium text-text">{pickText(r.text_en, r.text_ta, i18n.language)}</span>,
          },
          { key: "type", header: t("masters.followupQuestions.answerType"), render: (r) => t(`masters.followupQuestions.types.${r.answer_type}`) },
          { key: "req", header: t("masters.followupQuestions.required"), render: (r) => (r.is_required ? t("common.yes") : "—") },
          {
            key: "applies",
            header: t("masters.followupQuestions.appliesTo"),
            render: (r) => {
              const on = linkedTypes.get(r.id) ?? new Set<string>()
              return (
                <div className="flex flex-wrap items-center gap-1">
                  {FOLLOWUP_TICKET_TYPES.map((ty) => (
                    <button
                      key={ty}
                      type="button"
                      aria-pressed={on.has(ty)}
                      disabled={linkMut.isPending}
                      onClick={() =>
                        linkMut.mutate(
                          { orgId: orgId!, questionId: r.id, ticketType: ty, on: !on.has(ty) },
                          { onError: (e) => toast.error(e instanceof Error && e.message ? e.message : t("common.actionFailed")) }
                        )
                      }
                      className={cn("rounded-full border px-2 py-0.5 text-[11px] font-semibold", on.has(ty) ? "border-ink bg-ink text-white" : "border-border bg-surface text-text-muted")}
                    >
                      {t(`service.type.${ty}`)}
                    </button>
                  ))}
                  {on.size === 0 ? <span className="text-[11px] text-text-muted">{t("masters.followupQuestions.allTypes")}</span> : null}
                </div>
              )
            },
          },
          {
            key: "status",
            header: t("masters.leadKinds.status"),
            render: (r) => <StatusDot tone={r.is_active ? "success" : "neutral"} label={r.is_active ? t("masters.leadKinds.active") : t("masters.leadKinds.inactive")} />,
          },
        ]}
        onCreate={async (v) => {
          const type = (v.answer_type || "yes_no") as AnswerType
          const choices = choicesFor({ ...v, answer_type: type })
          const sort = v.sort_order?.trim() ? Number(v.sort_order) : rows.reduce((m, r) => Math.max(m, r.sort_order), 0) + 1
          return createMut.mutateAsync({
            org_id: orgId!,
            scope: "post_service",
            text_en: v.text_en.trim(),
            text_ta: (v.text_ta ?? "").trim(),
            answer_type: type,
            choices,
            is_required: v.is_required === "true",
            is_active: v.is_active !== "false",
            sort_order: sort,
          })
        }}
        onUpdate={async (id, v) => {
          const row = rows.find((r) => r.id === id)
          if (!row) throw new Error(t("common.actionFailed"))
          // the answer type is fixed after creation (the database refuses a change); only a choice question's list is editable
          const choices = row.answer_type === "choice" ? choicesFor({ ...v, answer_type: "choice" }) : null
          return updateMut.mutateAsync({
            id,
            patch: {
              text_en: v.text_en.trim(),
              text_ta: (v.text_ta ?? "").trim(),
              choices,
              is_required: v.is_required === "true",
              is_active: v.is_active !== "false",
              sort_order: v.sort_order?.trim() ? Number(v.sort_order) : row.sort_order,
            },
          })
        }}
        onDelete={async () => undefined}
        checkCanDelete={async () => false}
        cannotDeleteMessage={t("masters.followupQuestions.cannotDelete")}
      />
    </div>
  )
}

function isoDate(d: Date): string {
  const p = (n: number) => String(n).padStart(2, "0")
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}`
}

function AnswersReport() {
  const { t, i18n } = useTranslation()
  const [to, setTo] = useState(() => isoDate(new Date()))
  const [from, setFrom] = useState(() => isoDate(new Date(Date.now() - 29 * 86_400_000)))
  const valid = !!from && !!to && from <= to
  const report = useFollowupAnswersReport(from, to, valid)
  const rows = report.data ?? []

  return (
    <Card className="gap-3 px-5" data-testid="followup-answers-report">
      <div>
        <h3 className="text-sm font-semibold text-text">{t("masters.followupQuestions.reportTitle")}</h3>
        <p className="text-xs text-text-muted">{t("masters.followupQuestions.reportHint")}</p>
      </div>
      <div className="flex flex-wrap items-end gap-3">
        <div className="space-y-1">
          <Label htmlFor="fq-from">{t("masters.followupQuestions.from")}</Label>
          <Input id="fq-from" type="date" value={from} max={to} onChange={(e) => setFrom(e.target.value)} />
        </div>
        <div className="space-y-1">
          <Label htmlFor="fq-to">{t("masters.followupQuestions.to")}</Label>
          <Input id="fq-to" type="date" value={to} min={from} onChange={(e) => setTo(e.target.value)} />
        </div>
      </div>
      {!valid ? (
        <p className="text-xs text-danger">{t("masters.followupQuestions.badRange")}</p>
      ) : report.isLoading ? (
        <p className="text-xs text-text-muted">{t("common.loading")}</p>
      ) : report.isError ? (
        <p className="text-xs text-danger">{report.error instanceof Error ? report.error.message : t("common.error")}</p>
      ) : rows.length === 0 ? (
        <p className="text-sm text-text-muted">{t("masters.followupQuestions.reportEmpty")}</p>
      ) : (
        <div className="overflow-x-auto">
          <table className="w-full min-w-[520px] text-left text-xs">
            <thead className="text-text-muted">
              <tr>
                <th className="py-1.5 pr-3 font-semibold">{t("masters.followupQuestions.textEn")}</th>
                <th className="py-1.5 pr-3 font-semibold">{t("masters.followupQuestions.reportAnswers")}</th>
                <th className="py-1.5 font-semibold">{t("masters.followupQuestions.reportSummary")}</th>
              </tr>
            </thead>
            <tbody>
              {rows.map((r) => (
                <tr key={r.question_id} className="border-t border-border align-top">
                  <td className="py-2 pr-3 font-medium text-text">{pickText(r.text_en, r.text_ta, i18n.language)}</td>
                  <td className="gv-tnum py-2 pr-3">{r.answers}</td>
                  <td className="py-2 text-text">
                    {r.answer_type === "yes_no" ? `${t("common.yes")}: ${r.yes_count} · ${t("common.no")}: ${r.no_count}` : null}
                    {r.answer_type === "rating" ? (
                      <>
                        {t("masters.followupQuestions.average")}: <b>{r.rating_avg ?? "—"}</b>
                        {" · "}
                        {[1, 2, 3, 4, 5].map((n) => `${n}★ ${(r.rating_counts as Record<string, number> | null)?.[String(n)] ?? 0}`).join("  ")}
                      </>
                    ) : null}
                    {r.answer_type === "choice"
                      ? Object.entries((r.choice_counts as Record<string, number> | null) ?? {})
                          .map(([k, n]) => `${k}: ${n}`)
                          .join(" · ")
                      : null}
                    {r.answer_type === "text" ? t("masters.followupQuestions.textCount", { count: r.text_count }) : null}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </Card>
  )
}
