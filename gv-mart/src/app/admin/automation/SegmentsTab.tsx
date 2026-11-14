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
  useSegmentMatchCount,
  useSegmentMatchPreview,
  useSegmentRuns,
  useSendSegmentNow,
  useSetSegmentStanding,
} from "@/hooks/useAudienceSegments"
import { SEGMENT_FIELDS, type SegmentConditionLeaf, type SegmentConditionTree } from "@/services/audienceSegments"
import { cn } from "@/lib/utils"

/** Advanced/secondary automation — build an audience from any combination of customer + purchase
 * attributes, save it, pick an approved template, and send once or make it standing (auto-fires on
 * every future matching purchase). See build-docs/features/segment-builder.md. Separate from, and
 * additive to, EventTemplatesTab's fixed 12-template wiring above. */
function emptyTree(): SegmentConditionTree {
  return { op: "and", conditions: [{ field: SEGMENT_FIELDS[0].field, operator: "=", value: "" }] }
}

function ConditionBuilder({ tree, onChange }: { tree: SegmentConditionTree; onChange: (t: SegmentConditionTree) => void }) {
  const { t } = useTranslation()
  const leaves = tree.conditions as SegmentConditionLeaf[]

  const updateLeaf = (i: number, patch: Partial<SegmentConditionLeaf>) => {
    const next = leaves.map((l, idx) => (idx === i ? { ...l, ...patch } : l))
    onChange({ ...tree, conditions: next })
  }
  const addLeaf = () => onChange({ ...tree, conditions: [...leaves, { field: SEGMENT_FIELDS[0].field, operator: "=", value: "" }] })
  const removeLeaf = (i: number) => onChange({ ...tree, conditions: leaves.filter((_, idx) => idx !== i) })

  return (
    <div className="space-y-2">
      <div className="flex items-center gap-2 text-xs text-text-muted">
        <span>{t("automation.segments.matchAll")}</span>
        <select
          className="rounded border border-border bg-surface px-2 py-1 text-xs"
          value={tree.op}
          onChange={(e) => onChange({ ...tree, op: e.target.value as "and" | "or" })}
        >
          <option value="and">{t("automation.segments.opAnd")}</option>
          <option value="or">{t("automation.segments.opOr")}</option>
        </select>
        <span>{t("automation.segments.ofTheseConditions")}</span>
      </div>
      {leaves.map((leaf, i) => {
        const fieldDef = SEGMENT_FIELDS.find((f) => f.field === leaf.field) ?? SEGMENT_FIELDS[0]
        return (
          <div key={i} className="flex flex-wrap items-center gap-2">
            <select
              className="rounded border border-border bg-surface px-2 py-1 text-xs"
              value={leaf.field}
              onChange={(e) => updateLeaf(i, { field: e.target.value, value: fieldDef.kind === "boolean" ? true : "" })}
            >
              {SEGMENT_FIELDS.map((f) => (
                <option key={f.field} value={f.field}>
                  {f.label}
                </option>
              ))}
            </select>
            {fieldDef.kind === "boolean" ? (
              <select
                className="rounded border border-border bg-surface px-2 py-1 text-xs"
                value={String(leaf.value)}
                onChange={(e) => updateLeaf(i, { value: e.target.value === "true" })}
              >
                <option value="true">{t("automation.segments.yes")}</option>
                <option value="false">{t("automation.segments.no")}</option>
              </select>
            ) : (
              <input
                className="rounded border border-border bg-surface px-2 py-1 text-xs"
                placeholder={t("automation.segments.valuePlaceholder")}
                value={typeof leaf.value === "string" ? leaf.value : ""}
                onChange={(e) => updateLeaf(i, { value: e.target.value })}
              />
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
  const [tree, setTree] = useState<SegmentConditionTree>(emptyTree())
  const [templateName, setTemplateName] = useState("")

  const { data: templates } = useApprovedTemplateNames()
  const { data: count, isFetching: countLoading } = useSegmentMatchCount(orgId, tree)
  const previewMut = useSegmentMatchPreview()
  const saveMut = useSaveAudienceSegment()

  if (!open) {
    return (
      <Button size="sm" onClick={() => setOpen(true)}>
        <Plus className="size-4" /> {t("automation.segments.newSegment")}
      </Button>
    )
  }

  const validLeaves = (tree.conditions as SegmentConditionLeaf[]).every((l) => (typeof l.value === "boolean" ? true : String(l.value).trim().length > 0))

  return (
    <div className="space-y-3 rounded-lg border border-border p-3">
      <input
        className="w-full rounded border border-border bg-surface px-2 py-1.5 text-sm"
        placeholder={t("automation.segments.namePlaceholder")}
        value={name}
        onChange={(e) => setName(e.target.value)}
      />
      <ConditionBuilder tree={tree} onChange={setTree} />

      <div className="flex items-center gap-2">
        <span className="text-xs text-text-muted">{t("automation.segments.matchingNow")}:</span>
        {countLoading ? <Loader2 className="size-3.5 animate-spin" /> : <span className="font-bold">{count ?? 0}</span>}
        <Button
          size="sm"
          variant="outline"
          onClick={() => previewMut.mutate({ orgId, conditionTree: tree })}
          disabled={!validLeaves || previewMut.isPending}
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
          disabled={!name.trim() || !validLeaves || saveMut.isPending}
          onClick={async () => {
            await saveMut.mutateAsync({ orgId, name: name.trim(), conditionTree: tree, wasiTemplateName: templateName || null })
            setOpen(false)
            setName("")
            setTree(emptyTree())
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
                <td className="py-1">{new Date(r.fired_at).toLocaleString()}</td>
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
