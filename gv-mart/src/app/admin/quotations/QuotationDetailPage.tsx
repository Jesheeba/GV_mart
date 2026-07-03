import { useState } from "react"
import { useTranslation } from "react-i18next"
import { useNavigate, useParams } from "react-router-dom"
import { Button } from "@/components/ui/button"
import { Card } from "@/components/ui/card"
import { Input } from "@/components/ui/input"
import { StatusDot, type StatusTone } from "@/components/shared/StatusDot"
import { FullPageError, FullPageLoader } from "@/components/shared/FullPageLoader"
import { useProfile } from "@/hooks/useProfile"
import { useMarkQuotationLost, useQuotation } from "@/hooks/useQuotations"
import { formatCurrency } from "@/lib/sale-calc"

const STATUS_TONE: Record<string, StatusTone> = { open: "info", converted: "success", lost: "danger" }

export function QuotationDetailPage() {
  const { t } = useTranslation()
  const navigate = useNavigate()
  const { id } = useParams<{ id: string }>()
  const { data: profile } = useProfile()
  const orgId = profile?.org_id

  const { data: quotation, isLoading, isError, refetch } = useQuotation(orgId, id)
  const markLost = useMarkQuotationLost()
  const [lostReason, setLostReason] = useState("")
  const [showLostForm, setShowLostForm] = useState(false)

  if (isLoading) return <FullPageLoader label={t("common.loading")} />
  if (isError || !quotation) {
    return <FullPageError message={t("quotations.error.loadFailed")} onRetry={() => refetch()} retryLabel={t("common.retry")} />
  }

  return (
    <div className="mx-auto max-w-2xl space-y-4 pt-2">
      <div className="flex items-center justify-between">
        <Button type="button" variant="outline" onClick={() => navigate(-1)}>
          {t("sales.newSale.back")}
        </Button>
        <StatusDot tone={STATUS_TONE[quotation.status] ?? "neutral"} label={t(`quotations.status.${quotation.status}`)} />
      </div>

      <Card className="gap-3">
        <p className="text-lg font-bold text-text">{quotation.customers?.name}</p>
        <p className="text-sm text-text-muted">{quotation.customers?.mobile}</p>
        {quotation.valid_until ? (
          <p className="text-sm text-text-muted">
            {t("quotations.table.validUntil")}: {new Date(quotation.valid_until).toLocaleDateString("en-IN")}
          </p>
        ) : null}

        <div className="space-y-2 border-t border-border pt-3">
          {quotation.quotation_items.map((item) => (
            <div key={item.id} className="flex items-center justify-between text-sm">
              <span className="text-text">{item.itemName}</span>
              <span className="text-text-muted">
                {item.qty} × {formatCurrency(item.price)} = {formatCurrency(item.qty * item.price)}
              </span>
            </div>
          ))}
        </div>
        <div className="flex justify-between border-t border-border pt-2 text-base font-bold text-text">
          <span>{t("sales.summary.total")}</span>
          <span>{formatCurrency(quotation.total)}</span>
        </div>
        {quotation.lost_reason ? <p className="text-sm text-danger">{t("quotations.lostReasonLabel")}: {quotation.lost_reason}</p> : null}
      </Card>

      {quotation.status === "open" ? (
        <div className="space-y-3">
          <div className="flex flex-wrap gap-2">
            <Button type="button" variant="accent" onClick={() => navigate(`/admin/sales/new?fromQuotation=${quotation.id}`)}>
              {t("quotations.convertButton")}
            </Button>
            <Button type="button" variant="outline" onClick={() => setShowLostForm((v) => !v)}>
              {t("quotations.markLostButton")}
            </Button>
          </div>
          {showLostForm ? (
            <Card className="gap-2">
              <Input value={lostReason} onChange={(e) => setLostReason(e.target.value)} placeholder={t("quotations.lostReasonPlaceholder")} />
              <Button
                type="button"
                variant="destructive"
                size="sm"
                disabled={!lostReason.trim() || markLost.isPending}
                onClick={() => markLost.mutate({ id: quotation.id, reason: lostReason })}
              >
                {t("quotations.confirmLost")}
              </Button>
            </Card>
          ) : null}
        </div>
      ) : null}
    </div>
  )
}
