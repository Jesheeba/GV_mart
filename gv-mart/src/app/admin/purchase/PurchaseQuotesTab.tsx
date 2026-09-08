import { useEffect, useRef, useState } from "react"
import { useTranslation } from "react-i18next"
import { Loader2 } from "lucide-react"
import { Card } from "@/components/ui/card"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { StatusDot, type StatusTone } from "@/components/shared/StatusDot"
import { useProfile } from "@/hooks/useProfile"
import {
  useOpenPurchaseQuoteRequests,
  useResolvedPurchaseQuoteRequests,
  useResolvePurchaseQuoteRequests,
  useLogPurchaseQuoteReply,
  usePurchaseQuoteReplies,
  useQuoteDismissals,
  useMarkQuoteSupplierNoResponse,
  useGenerateQuoteRequestPdf,
} from "@/hooks/useAutomation"
import { useSuppliersForItem } from "@/hooks/useSuppliers"
import type { PurchaseQuoteRequestListItem } from "@/services/automation"

const RESOLUTION_TONE: Record<string, StatusTone> = { reply: "success", fallback: "warning", no_supplier: "danger", no_po_not_low_stock: "neutral" }

/**
 * GV.md Section 3 ("Purchase Order — quotation-first, with safeguard") admin
 * screen. See supabase/migrations/20260725120000_po_quotation_first_with_
 * timeout_safeguard.sql's header comment for the full design.
 *
 * "Resolve-on-view": there's no pg_cron in this stack, so nothing fires
 * exactly when a request's timeout elapses. Instead, every time this tab
 * mounts it calls resolve_purchase_quote_requests once (same shape as
 * useRefreshOperationalAlerts) — that closes out any request whose timeout
 * has already passed (lowest logged reply wins, or last-known-cheapest if
 * nobody replied) before rendering the lists below, so what's shown is
 * always caught up as of this page load.
 */
export function PurchaseQuotesTab() {
  const { t } = useTranslation()
  const { data: profile } = useProfile()
  const orgId = profile?.org_id

  const openReqs = useOpenPurchaseQuoteRequests(orgId)
  const resolvedReqs = useResolvedPurchaseQuoteRequests(orgId)
  const resolveMut = useResolvePurchaseQuoteRequests(orgId)

  // Run the resolve scan once per mount, not once per render/refetch — a ref
  // (not state) so it can't itself trigger a re-render/re-run loop.
  const ranRef = useRef(false)
  useEffect(() => {
    if (orgId && !ranRef.current) {
      ranRef.current = true
      resolveMut.mutate()
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [orgId])

  return (
    <div className="space-y-4">
      <p className="text-xs text-text-muted">{t("purchase.quotes.subtitle")}</p>

      <Card className="gap-3 px-5">
        <h3 className="text-sm font-semibold text-text">{t("purchase.quotes.openTitle")}</h3>
        <p className="text-xs text-text-muted">{t("purchase.quotes.openHint")}</p>
        {openReqs.isLoading || resolveMut.isPending ? (
          <p className="text-xs text-text-muted">{t("common.loading")}</p>
        ) : openReqs.data && openReqs.data.length > 0 ? (
          <div className="space-y-3">
            {openReqs.data.map((req) => (
              <OpenRequestCard key={req.id} orgId={orgId} req={req} />
            ))}
          </div>
        ) : (
          <p className="text-xs text-text-muted">{t("purchase.quotes.openEmpty")}</p>
        )}
      </Card>

      <Card className="gap-3 px-5">
        <h3 className="text-sm font-semibold text-text">{t("purchase.quotes.resolvedTitle")}</h3>
        {resolvedReqs.isLoading ? (
          <p className="text-xs text-text-muted">{t("common.loading")}</p>
        ) : resolvedReqs.data && resolvedReqs.data.length > 0 ? (
          <ul className="space-y-1.5 text-sm text-text">
            {resolvedReqs.data.map((req) => (
              <li key={req.id} className="flex flex-wrap items-center justify-between gap-2 border-b border-border py-2 last:border-0">
                <span>
                  {req.itemName} · {req.order_qty} {t("purchase.quotes.units")}
                </span>
                <StatusDot tone={RESOLUTION_TONE[req.resolution ?? ""] ?? "neutral"} label={t(`purchase.quotes.resolutions.${req.resolution ?? "unknown"}`)} />
                <span className="text-xs text-text-muted">{req.resolved_at ? new Date(req.resolved_at).toLocaleString("en-IN") : "—"}</span>
              </li>
            ))}
          </ul>
        ) : (
          <p className="text-xs text-text-muted">{t("purchase.quotes.resolvedEmpty")}</p>
        )}
      </Card>
    </div>
  )
}

function OpenRequestCard({ orgId, req }: { orgId: string | undefined; req: PurchaseQuoteRequestListItem }) {
  const { t } = useTranslation()
  const { data: candidateSuppliers } = useSuppliersForItem(orgId, req.item_type, req.item_id)
  const { data: replies } = usePurchaseQuoteReplies(req.id)
  const { data: dismissals } = useQuoteDismissals(req.id)
  const logReply = useLogPurchaseQuoteReply()
  const markNoResponse = useMarkQuoteSupplierNoResponse()
  const generatePdf = useGenerateQuoteRequestPdf()

  const [supplierId, setSupplierId] = useState("")
  const [price, setPrice] = useState("")

  const repliesBySupplier = new Map((replies ?? []).map((r) => [r.supplier_id, r]))
  const dismissedSupplierIds = new Set((dismissals ?? []).map((d) => d.supplier_id))
  const pastTimeout = new Date(req.timeout_at).getTime() <= Date.now()
  const lowestPrice = (replies ?? []).length ? Math.min(...(replies ?? []).map((r) => Number(r.price))) : null

  async function submit() {
    if (!supplierId || !price) return
    await logReply.mutateAsync({ requestId: req.id, supplierId, price: Number(price) })
    setSupplierId("")
    setPrice("")
  }

  return (
    <div className="rounded-xl border border-border p-3">
      <div className="flex flex-wrap items-center justify-between gap-2">
        <div className="text-sm font-medium text-text">
          {req.itemName} · {req.order_qty} {t("purchase.quotes.units")}
        </div>
        <div className="text-xs text-text-muted">
          {pastTimeout
            ? t("purchase.quotes.timedOutWaitingResolve")
            : t("purchase.quotes.timeoutAt", { time: new Date(req.timeout_at).toLocaleString("en-IN") })}
        </div>
      </div>

      {/* PDF-generation piece of the supplier document-quote-request work
          (compliance investigation, 2026-09-03) — standalone for now, not
          wired into any WhatsApp send yet (see generate-quote-pdf/index.ts's
          header comment for why). Lets an admin generate/regenerate and
          preview the letterhead document today. */}
      <div className="mt-2 flex flex-wrap items-center gap-2">
        <Button type="button" size="sm" variant="outline" disabled={generatePdf.isPending} onClick={() => generatePdf.mutate(req.id)}>
          {generatePdf.isPending ? <Loader2 className="size-3.5 animate-spin" /> : t("purchase.quotes.generatePdf")}
        </Button>
        {req.pdf_url ? (
          <a href={req.pdf_url} target="_blank" rel="noreferrer" className="text-xs text-accent hover:underline">
            {t("purchase.quotes.viewPdf")}
          </a>
        ) : null}
      </div>
      {generatePdf.isError ? <p className="mt-1 text-xs text-danger">{(generatePdf.error as Error).message}</p> : null}

      {/* Price comparison — every invited supplier, side by side, lowest reply highlighted */}
      {(candidateSuppliers ?? []).length > 0 ? (
        <table className="mt-2 w-full text-xs text-text">
          <tbody>
            {(candidateSuppliers ?? []).map((s) => {
              const reply = repliesBySupplier.get(s.supplier_id)
              const isLowest = reply != null && lowestPrice != null && Number(reply.price) === lowestPrice
              const isDismissed = dismissedSupplierIds.has(s.supplier_id)
              return (
                <tr key={s.supplier_id} className="border-b border-border/60 last:border-0">
                  <td className="py-1.5 pr-2">{s.suppliers?.name ?? "—"}</td>
                  <td className={`py-1.5 pr-2 text-right ${isLowest ? "font-semibold text-success" : ""}`}>
                    {reply ? `₹${Number(reply.price).toLocaleString("en-IN")}${isLowest ? ` (${t("purchase.quotes.lowest")})` : ""}` : "—"}
                  </td>
                  <td className="py-1.5 text-right">
                    {reply ? null : isDismissed ? (
                      <span className="text-text-muted">{t("purchase.quotes.noResponse")}</span>
                    ) : (
                      <button
                        type="button"
                        className="text-accent hover:underline disabled:opacity-50"
                        disabled={markNoResponse.isPending}
                        onClick={() => markNoResponse.mutate({ requestId: req.id, supplierId: s.supplier_id })}
                      >
                        {t("purchase.quotes.markNoResponse")}
                      </button>
                    )}
                  </td>
                </tr>
              )
            })}
          </tbody>
        </table>
      ) : (
        <p className="mt-2 text-xs text-text-muted">{t("purchase.quotes.noRepliesYet")}</p>
      )}

      <div className="mt-3 flex flex-wrap items-center gap-2">
        <select
          value={supplierId}
          onChange={(e) => setSupplierId(e.target.value)}
          className="h-9 rounded-xl border border-border bg-surface px-2 text-sm text-text outline-none"
        >
          <option value="">{t("purchase.quotes.selectSupplier")}</option>
          {(candidateSuppliers ?? []).map((s) => (
            <option key={s.supplier_id} value={s.supplier_id} disabled={repliesBySupplier.has(s.supplier_id)}>
              {s.suppliers?.name ?? "—"}
              {repliesBySupplier.has(s.supplier_id) ? ` (${t("purchase.quotes.alreadyLogged")})` : ""}
            </option>
          ))}
        </select>
        <Input
          type="number"
          min={0}
          step="0.01"
          className="w-28"
          placeholder={t("purchase.items.price")}
          value={price}
          onChange={(e) => setPrice(e.target.value)}
        />
        <Button size="sm" onClick={submit} disabled={!supplierId || !price || logReply.isPending}>
          {logReply.isPending ? <Loader2 className="size-3.5 animate-spin" /> : t("purchase.quotes.logReply")}
        </Button>
      </div>
      {logReply.isError ? <p className="mt-1 text-xs text-danger">{(logReply.error as Error).message}</p> : null}
    </div>
  )
}
