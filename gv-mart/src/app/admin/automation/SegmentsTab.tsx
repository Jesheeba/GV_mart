import { useState } from "react"
import { useTranslation } from "react-i18next"
import { Loader2, Plus, Radio, Send, Trash2 } from "lucide-react"
import { Button } from "@/components/ui/button"
import { useProfile } from "@/hooks/useProfile"
import {
  useApprovedTemplateNames,
  useAudienceSegments,
  useDeleteAudienceSegment,
  useSaveAudienceSegment,
  useSegmentFieldValues,
  useSegmentMatchCount,
  useSegmentMatchPreview,
  useSegmentRuns,
  useSendSegmentNow,
  useSetSegmentStanding,
} from "@/hooks/useAudienceSegments"
import { ChoiceSelect } from "@/components/shared/ChoiceSelect"
import {
  completeSegmentTree,
  emptySegmentDraft,
  emptySegmentLeaf,
  SEGMENT_FIELDS,
  SEGMENT_TEXT_OPERATORS,
  type SegmentDraftLeaf,
  type SegmentDraftTree,
} from "@/services/audienceSegments"
import { cn } from "@/lib/utils"
import { formatShortDateTime } from "@/lib/formatDate"

/** Advanced/secondary automation — build an audience from any combination of customer + purchase
 * attributes, save it, pick an approved template, and send once or make it standing (auto-fires on
 * every future matching purchase). See build-docs/features/segment-builder.md. Separate from, and
 * additive to, EventTemplatesTab's fixed 12-template wiring above. */

/** One leaf's value box — a native text input with a <datalist> of real existing values for the
 * chosen field, so the admin can pick from what's actually in the data instead of typing blind
 * (free typing still works; the datalist only suggests). */
function ConditionValueInput({ orgId, field, value, onChange }: { orgId: string; field: string; value: string; onChange: (v: string) => void }) {
  const { t } = useTranslation()
  const listId = `segment-field-values-${field}`
  const { data: suggestions } = useSegmentFieldValues(orgId, field, value)

  return (
    <>
      <input
        className="rounded border border-border bg-surface px-2 py-1 text-xs"
        placeholder={t("automation.segments.valuePlaceholder")}
        list={listId}
        value={value}
        onChange={(e) => onChange(e.target.value)}
      />
      <datalist id={listId}>
        {(suggestions ?? []).map((v) => (
          <option key={v} value={v} />
        ))}
      </datalist>
    </>
  )
}

/** Every select starts "Not set"; the parent only counts/previews/saves once completeSegmentTree() accepts the draft. */
function ConditionBuilder({ orgId, tree, onChange }: { orgId: string; tree: SegmentDraftTree; onChange: (t: SegmentDraftTree) => void }) {
  const { t } = useTranslation()
  const leaves = tree.conditions

  const updateLeaf = (i: number, patch: Partial<SegmentDraftLeaf>) => {
    const next = leaves.map((l, idx) => (idx === i ? { ...l, ...patch } : l))
    onChange({ ...tree, conditions: next })
  }
  const addLeaf = () => onChange({ ...tree, conditions: [...leaves, emptySegmentLeaf()] })
  const removeLeaf = (i: number) => onChange({ ...tree, conditions: leaves.filter((_, idx) => idx !== i) })

  return (
    <div className="space-y-2">
      <div className="flex items-center gap-2 text-xs text-text-muted">
        <span>{t("automation.segments.matchAll")}</span>
        <ChoiceSelect
          id="segment-op"
          label={`${t("automation.segments.matchAll")} … ${t("automation.segments.ofTheseConditions")}`}
          labelClassName="sr-only"
          value={tree.op}
          options={[
            { value: "and", label: t("automation.segments.opAnd") },
            { value: "or", label: t("automation.segments.opOr") },
          ]}
          onChange={(op) => onChange({ ...tree, op })}
        />
        <span>{t("automation.segments.ofTheseConditions")}</span>
      </div>
      {leaves.map((leaf, i) => {
        const isBoolean = SEGMENT_FIELDS.find((f) => f.field === leaf.field)?.kind === "boolean"
        return (
          <div key={i} className="flex flex-wrap items-center gap-2">
            <ChoiceSelect
              id={`segment-field-${i}`}
              label={`${t("masters.productEnquiryConfig.field")} ${i + 1}`}
              labelClassName="sr-only"
              value={leaf.field}
              options={SEGMENT_FIELDS.map((f) => ({ value: f.field, label: f.label }))}
              // A new field resets its operator and value to "Not set".
              onChange={(field) => updateLeaf(i, { field, operator: "", value: "" })}
            />
            {isBoolean ? (
              <ChoiceSelect
                id={`segment-value-${i}`}
                label={t("automation.segments.valuePlaceholder")}
                labelClassName="sr-only"
                value={leaf.value === "" ? "" : String(leaf.value) as "true" | "false"}
                options={[
                  { value: "true", label: t("automation.segments.yes") },
                  { value: "false", label: t("automation.segments.no") },
                ]}
                onChange={(v) => updateLeaf(i, { value: v === "" ? "" : v === "true" })}
              />
            ) : (
              <>
                <ChoiceSelect
                  id={`segment-operator-${i}`}
                  label={`${t("automation.segments.operator.equals")} / ${t("automation.segments.operator.contains")}`}
                  labelClassName="sr-only"
                  value={leaf.operator as (typeof SEGMENT_TEXT_OPERATORS)[number]["operator"] | ""}
                  options={SEGMENT_TEXT_OPERATORS.map((o) => ({
                    value: o.operator,
                    label: t(`automation.segments.operator.${o.operator === "=" ? "equals" : "contains"}`),
                  }))}
                  onChange={(operator) => updateLeaf(i, { operator })}
                />
                <ConditionValueInput
                  orgId={orgId}
                  field={leaf.field}
                  value={typeof leaf.value === "string" ? leaf.value : ""}
                  onChange={(v) => updateLeaf(i, { value: v })}
                />
              </>
            )}
            <Button size="sm" variant="ghost" onClick={() => removeLeaf(i)} disabled={leaves.length <= 1}>
              <Trash2 className="size-3.5" />
            </Button>
          </div>
        )
      })}
      <Button size="sm" variant="outline" onClick={addLeaf}>
        <Plus className="size-3.5" /> {t("automation.segments.addCondition")}
      </Button>
    </div>
  )
}

function NewSegmentPanel({ orgId }: { orgId: string }) {
  const { t } = useTranslation()
  const [open, setOpen] = useState(false)
  const [name, setName] = useState("")
  const [tree, setTree] = useState<SegmentDraftTree>(emptySegmentDraft)
  const [templateName, setTemplateName] = useState("")
  // null while any rule part is "Not set" — the count, preview and save all wait for a complete rule.
  const complete = completeSegmentTree(tree)

  const { data: templates } = useApprovedTemplateNames()
  const { data: count, isFetching: countLoading } = useSegmentMatchCount(orgId, complete ?? undefined)
  const previewMut = useSegmentMatchPreview()
  const saveMut = useSaveAudienceSegment()

  if (!open) {
    return (
      <Button size="sm" onClick={() => setOpen(true)}>
        <Plus className="size-4" /> {t("automation.segments.newSegment")}
      </Button>
    )
  }

  return (
    <div className="space-y-3 rounded-lg border border-border p-3">
      <input
        className="w-full rounded border border-border bg-surface px-2 py-1.5 text-sm"
        placeholder={t("automation.segments.namePlaceholder")}
        value={name}
        onChange={(e) => setName(e.target.value)}
      />
      <ConditionBuilder orgId={orgId} tree={tree} onChange={setTree} />

      <div className="flex items-center gap-2">
        <span className="text-xs text-text-muted">{t("automation.segments.matchingNow")}:</span>
        {!complete ? <span className="font-bold">—</span> : countLoading ? <Loader2 className="size-3.5 animate-spin" /> : <span className="font-bold">{count ?? 0}</span>}
        <Button
          size="sm"
          variant="outline"
          onClick={() => complete && previewMut.mutate({ orgId, conditionTree: complete })}
          disabled={!complete || previewMut.isPending}
        >
          {t("automation.segments.preview")}
        </Button>
      </div>

      {previewMut.data && (
        <ul className="rounded border border-border/50 bg-surface-alt p-2 text-xs">
          {previewMut.data.length === 0 ? (
            <li className="text-text-muted">{t("automation.segments.noMatches")}</li>
          ) : (
            previewMut.data.map((c) => (
              <li key={c.customer_id}>
                {c.name} — {c.mobile}
              </li>
            ))
          )}
        </ul>
      )}

      <select className="rounded border border-border bg-surface px-2 py-1 text-xs" value={templateName} onChange={(e) => setTemplateName(e.target.value)}>
        <option value="">{t("automation.segments.chooseTemplate")}</option>
        {templates?.map((n) => (
          <option key={n} value={n}>
            {n}
          </option>
        ))}
      </select>

      <div className="flex gap-2">
        <Button
          size="sm"
          disabled={!name.trim() || !complete || saveMut.isPending}
          onClick={async () => {
            if (!complete) return
            await saveMut.mutateAsync({ orgId, name: name.trim(), conditionTree: complete, wasiTemplateName: templateName || null })
            setOpen(false)
            setName("")
            setTree(emptySegmentDraft())
            setTemplateName("")
          }}
        >
          {saveMut.isPending ? <Loader2 className="size-3.5 animate-spin" /> : t("automation.segments.save")}
        </Button>
        <Button size="sm" variant="ghost" onClick={() => setOpen(false)}>
          {t("automation.segments.cancel")}
        </Button>
      </div>
    </div>
  )
}

function SegmentRow({ segment }: { segment: import("@/services/audienceSegments").AudienceSegmentRow }) {
  const { t } = useTranslation()
  const [showRuns, setShowRuns] = useState(false)
  const sendMut = useSendSegmentNow()
  const standingMut = useSetSegmentStanding()
  const deleteMut = useDeleteAudienceSegment()
  const { data: runs } = useSegmentRuns(showRuns ? segment.id : undefined)

  const noTemplate = !segment.wasi_template_name

  return (
    <div className="space-y-2 rounded-lg border border-border p-3">
      <div className="flex flex-wrap items-center justify-between gap-2">
        <div>
          <p className="font-medium">{segment.name}</p>
          <p className="font-mono text-xs text-text-muted">{segment.wasi_template_name ?? t("automation.segments.noTemplateChosen")}</p>
        </div>
        <div className="flex items-center gap-2">
          <Button
            size="sm"
            variant="outline"
            className={cn("border-transparent font-bold", segment.is_standing ? "bg-success/10 text-success" : "bg-surface-alt text-text-muted")}
            disabled={noTemplate || standingMut.isPending}
            onClick={() => standingMut.mutate({ segmentId: segment.id, isStanding: !segment.is_standing, wasiTemplateName: segment.wasi_template_name })}
            title={noTemplate ? t("automation.segments.chooseTemplateFirst") : undefined}
          >
            <Radio className="size-3.5" /> {segment.is_standing ? t("automation.segments.standingOn") : t("automation.segments.standingOff")}
          </Button>
          <Button size="sm" disabled={noTemplate || sendMut.isPending} onClick={() => sendMut.mutate(segment.id)}>
            {sendMut.isPending ? <Loader2 className="size-3.5 animate-spin" /> : <Send className="size-3.5" />} {t("automation.segments.sendNow")}
          </Button>
          <Button size="sm" variant="ghost" onClick={() => setShowRuns((v) => !v)}>
            {t("automation.segments.results")}
          </Button>
          <Button size="sm" variant="ghost" onClick={() => deleteMut.mutate(segment.id)}>
            <Trash2 className="size-3.5" />
          </Button>
        </div>
      </div>
      {showRuns && (
        <table className="w-full text-xs">
          <thead>
            <tr className="text-left text-text-muted">
              <th className="py-1">{t("automation.segments.runMode")}</th>
              <th className="py-1">{t("automation.segments.matched")}</th>
              <th className="py-1">{t("automation.segments.queued")}</th>
              <th className="py-1">{t("automation.segments.skippedOptOut")}</th>
              <th className="py-1">{t("automation.segments.skippedRecent")}</th>
              <th className="py-1">{t("automation.segments.firedAt")}</th>
            </tr>
          </thead>
          <tbody>
            {(runs ?? []).map((r) => (
              <tr key={r.id} className="border-t border-border/50">
                <td className="py-1">{r.mode}</td>
                <td className="py-1">{r.matched_count}</td>
                <td className="py-1">{r.queued_count}</td>
                <td className="py-1">{r.skipped_opted_out_count}</td>
                <td className="py-1">{r.skipped_recent_count}</td>
                <td className="whitespace-nowrap py-1">{formatShortDateTime(r.fired_at)}</td>
              </tr>
            ))}
            {!runs?.length && (
              <tr>
                <td colSpan={6} className="py-1 text-text-muted">
                  {t("automation.segments.noRuns")}
                </td>
              </tr>
            )}
          </tbody>
        </table>
      )}
    </div>
  )
}

export function SegmentsTab() {
  const { t } = useTranslation()
  const { data: profile } = useProfile()
  const orgId = profile?.org_id
  const isMaster = profile?.role === "master"
  const { data: segments, isLoading } = useAudienceSegments(orgId)

  if (!isMaster) {
    return <p className="text-sm text-text-muted">{t("automation.segments.masterOnly")}</p>
  }

  return (
    <div className="space-y-3">
      <p className="text-xs text-text-muted">{t("automation.segments.hint")}</p>
      {orgId && <NewSegmentPanel orgId={orgId} />}
      {isLoading ? (
        <Loader2 className="size-5 animate-spin text-text-muted" />
      ) : !segments?.length ? (
        <p className="text-sm text-text-muted">{t("automation.segments.empty")}</p>
      ) : (
        <div className="space-y-2">
          {segments.map((s) => (
            <SegmentRow key={s.id} segment={s} />
          ))}
        </div>
      )}
    </div>
  )
}
