import { useState } from "react"
import { useTranslation } from "react-i18next"
import { Camera, Loader2 } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Card } from "@/components/ui/card"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { useProfile } from "@/hooks/useProfile"
import { usePendingExpenseClaims, usePetrolReferenceAmount, useVerifyExpenseClaim } from "@/hooks/useMonthlyExpenses"
import { expenseClaimPhotoSignedUrl } from "@/services/monthlyExpenses"

/**
 * Monthly Expenses spec Unit 3 — verification queue. Owner revision: for
 * BOTH petrol and maintenance, the amount entered here is what gets paid
 * (compute_salary reads `verified_amount`). For petrol, the kilometres x
 * rate figure is shown only as a REFERENCE the admin can check the bill
 * against — it is never submitted as the payment.
 */
export function VerificationQueueTab() {
  const { t } = useTranslation()
  const { data: profile } = useProfile()
  const pending = usePendingExpenseClaims(profile?.org_id)

  if (pending.isLoading) return <p className="text-sm text-text-muted">{t("common.loading")}</p>
  if (!pending.data || pending.data.length === 0) {
    return (
      <Card className="items-center gap-2 py-8 text-center">
        <p className="text-sm font-medium text-text">{t("expenses.verification.empty")}</p>
      </Card>
    )
  }

  return (
    <div className="space-y-2.5">
      {pending.data.map((claim) => (
        <ClaimCard key={claim.id} orgId={profile?.org_id} claim={claim} />
      ))}
    </div>
  )
}

function ClaimCard({
  orgId,
  claim,
}: {
  orgId: string | undefined
  claim: { id: string; technician_id: string; period: string; claim_type: string; submitted_amount: number; bill_photo_path: string; technicians: { profiles: { full_name: string } | null } | null }
}) {
  const { t } = useTranslation()
  const verify = useVerifyExpenseClaim()
  const reference = usePetrolReferenceAmount(claim.claim_type === "petrol" ? orgId : undefined, claim.claim_type === "petrol" ? claim.technician_id : undefined, claim.period)
  const [verifiedAmount, setVerifiedAmount] = useState(String(claim.submitted_amount))
  const [reason, setReason] = useState("")
  const [viewing, setViewing] = useState(false)
  const [viewError, setViewError] = useState<string | null>(null)

  async function viewPhoto() {
    setViewing(true)
    setViewError(null)
    try {
      const url = await expenseClaimPhotoSignedUrl(claim.bill_photo_path)
      window.open(url, "_blank", "noopener,noreferrer")
    } catch (e) {
      setViewError((e as Error).message)
    } finally {
      setViewing(false)
    }
  }

  async function submit() {
    await verify.mutateAsync({ claimId: claim.id, verifiedAmount: Number(verifiedAmount), reason: reason.trim() || null })
  }

  const differs = Number(verifiedAmount) !== claim.submitted_amount

  return (
    <Card className="gap-2.5">
      <div className="flex items-start justify-between gap-2">
        <div>
          <p className="text-sm font-semibold text-text">{claim.technicians?.profiles?.full_name ?? "—"}</p>
          <p className="text-xs text-text-muted">
            {t(`expenses.claimTypeValues.${claim.claim_type}`)} · {claim.period}
          </p>
        </div>
        <Button type="button" size="sm" variant="outline" disabled={viewing} onClick={viewPhoto}>
          {viewing ? <Loader2 className="size-3.5 animate-spin" /> : <Camera className="size-3.5" />}
          {t("expenses.verification.viewBill")}
        </Button>
      </div>
      {viewError ? <p className="text-xs text-danger">{viewError}</p> : null}

      <div className="grid grid-cols-2 gap-3">
        <div>
          <Label>{t("expenses.verification.submittedAmount")}</Label>
          <p className="text-sm text-text">₹{claim.submitted_amount}</p>
        </div>
        {claim.claim_type === "petrol" ? (
          <div>
            <Label>{t("expenses.verification.referenceFigure")}</Label>
            <p className="text-sm text-text">{reference.data != null ? `₹${reference.data}` : "—"}</p>
          </div>
        ) : null}
      </div>

      <div className="space-y-1">
        <Label htmlFor={`verified-${claim.id}`}>{t("expenses.verification.amountToPay")}</Label>
        <Input id={`verified-${claim.id}`} type="number" min={0} step="0.5" value={verifiedAmount} onChange={(e) => setVerifiedAmount(e.target.value)} />
      </div>
      {differs ? (
        <div className="space-y-1">
          <Label htmlFor={`reason-${claim.id}`}>{t("expenses.verification.reasonRequired")}</Label>
          <Input id={`reason-${claim.id}`} value={reason} onChange={(e) => setReason(e.target.value)} />
        </div>
      ) : null}

      {verify.isError ? <p className="text-xs text-danger">{(verify.error as Error).message}</p> : null}
      <Button type="button" size="sm" disabled={verify.isPending || (differs && !reason.trim())} onClick={submit}>
        {t("expenses.verification.confirm")}
      </Button>
    </Card>
  )
}
