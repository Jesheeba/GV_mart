import { useState } from "react"
import { useTranslation } from "react-i18next"
import { useQueryClient } from "@tanstack/react-query"
import { Loader2, Plus, Search, TriangleAlert, Trash2 } from "lucide-react"
import { Input } from "@/components/ui/input"
import { Card } from "@/components/ui/card"
import { Button } from "@/components/ui/button"
import { useSpareSearch, useSparesForComplaintType } from "@/hooks/useTechnician"
import { filterDueOrOverdueParts, useDueParts, type CustomerPartSchedule } from "@/hooks/useDueParts"
import { enqueue } from "@/lib/offline/outbox"
import { getIstNow } from "@/lib/ist"
import { formatCurrency } from "@/lib/sale-calc"
import { cn } from "@/lib/utils"

// GV.md 1.1/D4: standardTimeMinutes (admin-set on the spare master) rides
// along with each selection so the SOP step (next in the flow — see
// OnSiteVisitPage's reordered STEP_KEYS) can seed its checklist directly
// from these picks instead of free text.
export type SelectedSpare = { spareId: string; name: string; sku: string | null; price: number; qty: number; standardTimeMinutes: number | null }

/**
 * Product Lifecycle & Automated Service Reminder System — inline "Mark
 * Replaced" form for one due/overdue part schedule row. A small spare-used
 * picker is wired up locally (its own `useSpareSearch` term/results, same
 * hook the main picker above already uses) rather than reusing the main
 * picker's own `term` state, since naming the replacement spare here must
 * not disturb whatever the technician already has typed into the main
 * search box for this visit's actual spare consumption.
 */
function MarkReplacedForm({
  orgId,
  schedule,
  visitId,
  onDone,
  onCancel,
}: {
  orgId: string | undefined
  schedule: CustomerPartSchedule
  visitId: string | null | undefined
  onDone: () => void
  onCancel: () => void
}) {
  const { t } = useTranslation()
  const [replacedDate, setReplacedDate] = useState(() => getIstNow().date)
  const [spareTerm, setSpareTerm] = useState("")
  const [spareUsed, setSpareUsed] = useState<{ id: string; name: string } | null>(null)
  const [submitting, setSubmitting] = useState(false)
  const spareResults = useSpareSearch(orgId, spareTerm)

  async function handleSubmit() {
    setSubmitting(true)
    try {
      // Additive-only contract (outboxContract.ts) — spareUsedId/visitId are
      // still present KEYS here even when null, matching how every other
      // optional field in this codebase's outbox payloads is handled.
      await enqueue(
        "product_lifecycle.mark_replaced",
        { scheduleId: schedule.id, replacedDate, spareUsedId: spareUsed?.id ?? null, visitId: visitId ?? null },
        crypto.randomUUID()
      )
    } finally {
      setSubmitting(false)
    }
    onDone()
  }

  return (
    <div className="space-y-2.5 rounded-xl border border-border bg-surface-alt p-3">
      <p className="text-xs font-semibold text-text">{t("technicianLifecycle.markReplacedForm.title", { label: schedule.label })}</p>
      <div className="space-y-1">
        <label className="text-xs text-text-muted">{t("technicianLifecycle.markReplacedForm.replacedDate")}</label>
        <Input type="date" value={replacedDate} max={getIstNow().date} onChange={(e) => setReplacedDate(e.target.value)} />
      </div>
      <div className="space-y-1">
        <label className="text-xs text-text-muted">{t("technicianLifecycle.markReplacedForm.spareUsed")}</label>
        {spareUsed ? (
          <div className="flex items-center justify-between rounded-lg border border-border px-3 py-2 text-sm">
            <span className="truncate text-text">{spareUsed.name}</span>
            <Button type="button" variant="ghost" size="icon-sm" onClick={() => setSpareUsed(null)}>
              <Trash2 className="size-3.5 text-danger" />
            </Button>
          </div>
        ) : (
          <>
            <div className="relative">
              <Search className="pointer-events-none absolute left-3 top-1/2 size-3.5 -translate-y-1/2 text-text-muted" />
              <Input
                value={spareTerm}
                onChange={(e) => setSpareTerm(e.target.value)}
                placeholder={t("technicianLifecycle.markReplacedForm.spareUsedPlaceholder")}
                className="pl-9"
              />
            </div>
            {spareTerm.trim() ? (
              <div className="max-h-32 space-y-1 overflow-auto rounded-xl border border-border">
                {spareResults.isFetching ? (
                  <div className="flex items-center gap-2 px-3 py-2 text-sm text-text-muted">
                    <Loader2 className="size-3.5 animate-spin" /> {t("common.loading")}
                  </div>
                ) : !spareResults.data || spareResults.data.length === 0 ? (
                  <p className="px-3 py-2 text-sm text-text-muted">{t("technician.onsite.spares.empty")}</p>
                ) : (
                  spareResults.data.map((s) => (
                    <button
                      key={s.id}
                      type="button"
                      onClick={() => {
                        setSpareUsed({ id: s.id, name: s.name })
                        setSpareTerm("")
                      }}
                      className="flex w-full items-center justify-between px-3 py-2 text-left text-sm hover:bg-surface"
                    >
                      <span className="font-medium text-text">{s.name}</span>
                      <span className="text-text-muted">{formatCurrency(Number(s.price))}</span>
                    </button>
                  ))
                )}
              </div>
            ) : null}
          </>
        )}
      </div>
      <div className="flex justify-end gap-2">
        <Button type="button" variant="ghost" size="sm" onClick={onCancel} disabled={submitting}>
          {t("technicianLifecycle.markReplacedForm.cancel")}
        </Button>
        <Button type="button" size="sm" onClick={handleSubmit} disabled={submitting || !replacedDate}>
          {submitting ? <Loader2 className="size-3.5 animate-spin" /> : null}
          {t("technicianLifecycle.markReplacedForm.submit")}
        </Button>
      </div>
    </div>
  )
}

/**
 * Product Lifecycle & Automated Service Reminder System — warning list of
 * due/overdue part schedules for the visit's customer, shown above the
 * existing spare picker so a technician sees "this customer has a part due"
 * at the same moment they're already picking spares for this job.
 */
function DuePartsWarningList({
  orgId,
  customerId,
  visitId,
}: {
  orgId: string | undefined
  customerId: string | undefined
  visitId: string | null | undefined
}) {
  const { t } = useTranslation()
  const qc = useQueryClient()
  const dueParts = useDueParts(customerId)
  const [openScheduleId, setOpenScheduleId] = useState<string | null>(null)
  // Optimistic hide: a job just marked replaced shouldn't still show in this
  // list while the outbox job is still pending sync (sync.ts flushes on its
  // own poll, same reasoning as useStartVisit's onMutate in useTechnician.ts
  // — don't wait on a refetch that may land before the real row changes).
  const [justReplacedIds, setJustReplacedIds] = useState<Set<string>>(new Set())

  const rows = filterDueOrOverdueParts(dueParts.data).filter((p) => !justReplacedIds.has(p.id))
  if (!customerId || rows.length === 0) return null

  function statusLabel(p: CustomerPartSchedule) {
    const key =
      p.status === "overdue" ? "technicianLifecycle.warningList.overdue" : p.status === "due" ? "technicianLifecycle.warningList.due" : "technicianLifecycle.warningList.dueSoon"
    return t(key, { date: new Date(p.nextDueDate).toLocaleDateString("en-IN") })
  }

  return (
    <Card className="gap-2.5 border-warning/40 bg-warning/5">
      <p className="flex items-center gap-1.5 px-1 text-sm font-semibold text-text">
        <TriangleAlert className="size-3.5 text-warning" />
        {t("technicianLifecycle.warningList.title")}
      </p>
      <div className="space-y-2">
        {rows.map((p) => (
          <div key={p.id} className="space-y-2">
            <div className="flex items-center justify-between gap-2 px-1">
              <div className="min-w-0">
                <p className="truncate text-sm font-medium text-text">{p.label}</p>
                <p className={cn("text-xs", p.status === "overdue" ? "text-danger" : "text-text-muted")}>{statusLabel(p)}</p>
              </div>
              {openScheduleId !== p.id ? (
                <Button type="button" variant="outline" size="xs" className="shrink-0" onClick={() => setOpenScheduleId(p.id)}>
                  {t("technicianLifecycle.warningList.markReplaced")}
                </Button>
              ) : null}
            </div>
            {openScheduleId === p.id ? (
              <MarkReplacedForm
                orgId={orgId}
                schedule={p}
                visitId={visitId}
                onCancel={() => setOpenScheduleId(null)}
                onDone={() => {
                  setOpenScheduleId(null)
                  setJustReplacedIds((prev) => new Set(prev).add(p.id))
                  void qc.invalidateQueries({ queryKey: ["dueParts", customerId] })
                }}
              />
            ) : null}
          </div>
        ))}
      </div>
    </Card>
  )
}

export function SpareSelectStep({
  orgId,
  complaintTypeId,
  customerId,
  visitId,
  selected,
  onChange,
}: {
  orgId: string | undefined
  /** Issue-based spare suggestions (2026-08-06) — the job's complaint_type,
   * for the "suggested" quick-add list below (replaces the earlier
   * product-based mapping: which spares fix *this issue* is more useful
   * than which spares are generically associated with the product). Free
   * search always stays available alongside it: the mapping is
   * admin-curated and may be incomplete or the ticket's complaint may be
   * free-typed with no matching complaint_types row, so it must never be
   * the only way to log a spare. */
  complaintTypeId: string | null | undefined
  /** Product Lifecycle & Automated Service Reminder System — feeds the due-parts warning list above the picker. */
  customerId: string | undefined
  /** Same, for the optional visitId on a "Mark Replaced" payload — null before a visit row exists yet. */
  visitId: string | null | undefined
  selected: SelectedSpare[]
  onChange: (next: SelectedSpare[]) => void
}) {
  const { t } = useTranslation()
  const [term, setTerm] = useState("")
  const results = useSpareSearch(orgId, term)
  const suggested = useSparesForComplaintType(complaintTypeId ?? undefined)
  const suggestedToShow = (suggested.data ?? []).filter((s) => !selected.some((sel) => sel.spareId === s.id))

  function addSpare(spare: { id: string; name: string; sku: string | null; price: number; standard_time_minutes: number | null }) {
    if (selected.some((s) => s.spareId === spare.id)) return
    onChange([
      ...selected,
      { spareId: spare.id, name: spare.name, sku: spare.sku, price: Number(spare.price), qty: 1, standardTimeMinutes: spare.standard_time_minutes },
    ])
    setTerm("")
  }

  function setQty(spareId: string, qty: number) {
    onChange(selected.map((s) => (s.spareId === spareId ? { ...s, qty: Math.max(1, qty) } : s)))
  }

  function remove(spareId: string) {
    onChange(selected.filter((s) => s.spareId !== spareId))
  }

  return (
    <>
      <DuePartsWarningList orgId={orgId} customerId={customerId} visitId={visitId} />
      <Card className="gap-3">
        <p className="px-1 text-sm font-semibold text-text">{t("technician.onsite.spares.title")}</p>
        <div className="relative">
          <Search className="pointer-events-none absolute left-3.5 top-1/2 size-4 -translate-y-1/2 text-text-muted" />
          <Input value={term} onChange={(e) => setTerm(e.target.value)} placeholder={t("technician.onsite.spares.searchPlaceholder")} className="pl-10" />
        </div>
        {!term.trim() && suggestedToShow.length > 0 ? (
          <div className="space-y-1.5">
            <p className="px-1 text-xs font-medium text-text-muted">{t("technician.onsite.spares.suggestedTitle")}</p>
            <div className="flex flex-wrap gap-1.5">
              {suggestedToShow.map((s) => (
                <button
                  key={s.id}
                  type="button"
                  onClick={() => addSpare({ id: s.id, name: s.name, sku: s.sku, price: Number(s.price), standard_time_minutes: s.standard_time_minutes })}
                  className="flex items-center gap-1 rounded-full border border-border bg-surface-alt px-3 py-1.5 text-xs font-medium text-text hover:border-accent hover:text-accent"
                >
                  <Plus className="size-3" />
                  {s.name}
                  {s.sku ? <span className="text-text-muted">({s.sku})</span> : null}
                </button>
              ))}
            </div>
          </div>
        ) : null}

        {term.trim() ? (
          <div className="max-h-48 space-y-1 overflow-auto rounded-xl border border-border">
            {results.isFetching ? (
              <div className="flex items-center gap-2 px-3.5 py-2.5 text-sm text-text-muted">
                <Loader2 className="size-3.5 animate-spin" /> {t("common.loading")}
              </div>
            ) : !results.data || results.data.length === 0 ? (
              <p className="px-3.5 py-2.5 text-sm text-text-muted">{t("technician.onsite.spares.empty")}</p>
            ) : (
              results.data.map((s) => (
                <button
                  key={s.id}
                  type="button"
                  onClick={() => addSpare({ id: s.id, name: s.name, sku: s.sku, price: Number(s.price), standard_time_minutes: s.standard_time_minutes })}
                  className="flex w-full items-center justify-between px-3.5 py-2.5 text-left text-sm hover:bg-surface-alt"
                >
                  <span>
                    <span className="font-medium text-text">{s.name}</span>{" "}
                    <span className="text-text-muted">{s.sku}</span>
                  </span>
                  <span className="flex items-center gap-1.5 text-text-muted">
                    {formatCurrency(Number(s.price))}
                    <Plus className="size-3.5" />
                  </span>
                </button>
              ))
            )}
          </div>
        ) : null}

        {selected.length === 0 ? (
          <p className="px-1 text-xs text-text-muted">{t("technician.onsite.spares.noneSelected")}</p>
        ) : (
          <div className="divide-y divide-border">
            {selected.map((s) => (
              <div key={s.spareId} className="flex items-center justify-between gap-2 px-1 py-2">
                <div className="min-w-0">
                  <p className="truncate text-sm font-medium text-text">{s.name}</p>
                  <p className="text-xs text-text-muted">
                    {formatCurrency(s.price)} × {s.qty}
                    {/* GV.md 1.1: shows the checklist step this selection will seed, so the technician sees the time cost up front. */}
                    {s.standardTimeMinutes ? ` · ${t("technician.onsite.spares.standardTime", { minutes: s.standardTimeMinutes })}` : null}
                  </p>
                </div>
                <div className="flex shrink-0 items-center gap-2">
                  <Input
                    type="number"
                    min={1}
                    value={s.qty}
                    onChange={(e) => setQty(s.spareId, Number(e.target.value) || 1)}
                    className="h-8 w-16 px-2 text-center"
                  />
                  <Button type="button" variant="ghost" size="icon-sm" onClick={() => remove(s.spareId)}>
                    <Trash2 className="size-3.5 text-danger" />
                  </Button>
                </div>
              </div>
            ))}
          </div>
        )}
      </Card>
    </>
  )
}
