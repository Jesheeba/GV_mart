import { useRef, useState } from "react"
import { useTranslation } from "react-i18next"
import { useNavigate } from "react-router-dom"
import { Camera, CheckCircle2, History, ImagePlus, Loader2, TriangleAlert } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Card } from "@/components/ui/card"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { DatePicker } from "@/components/ui/date-picker"
import { FullPageError, FullPageLoader } from "@/components/shared/FullPageLoader"
import { InlineErrorState } from "@/components/shared/InlineErrorState"
import { useProfile } from "@/hooks/useProfile"
import { useMyTechnician } from "@/hooks/useTechnician"
import { useAddKmLogEntry, useKmLogMonthlySum, useSubmitExpenseClaim } from "@/hooks/useMonthlyExpenses"
import { uploadExpenseClaimPhoto } from "@/services/monthlyExpenses"
import { isNotYetAvailableError } from "@/lib/supabaseErrors"

/**
 * Monthly Expenses spec Units 2/3 — technician side: submit a petrol or
 * maintenance bill (photo + amount) and add a kilometre log entry. Photo
 * capture mirrors PaymentProofUpload.tsx's dual-input (gallery + camera)
 * shape; submit-then-see-status mirrors SpareHandoverPage.tsx.
 */
export function ExpensesPage() {
  const { t } = useTranslation()
  const navigate = useNavigate()
  const { data: profile } = useProfile()
  const technician = useMyTechnician()

  if (technician.isLoading) return <FullPageLoader label={t("common.loading")} />
  if (technician.isError || !technician.data) {
    return <FullPageError message={t("technician.errors.loadFailed")} onRetry={() => technician.refetch()} retryLabel={t("common.retry")} />
  }

  return (
    <div className="space-y-4 pt-2">
      <div className="flex items-center justify-between gap-2">
        <h1 className="text-xl font-bold text-text">{t("technician.expenses.title")}</h1>
        <Button type="button" size="icon-sm" variant="outline" title={t("technician.expenses.history")} onClick={() => navigate("/technician/expenses/history")}>
          <History className="size-4" />
        </Button>
      </div>

      <ClaimForm orgId={profile?.org_id} technicianId={technician.data.id} claimType="petrol" />
      <ClaimForm orgId={profile?.org_id} technicianId={technician.data.id} claimType="maintenance" />
      <KmLogForm orgId={profile?.org_id} technicianId={technician.data.id} />
    </div>
  )
}

function ClaimForm({ orgId, technicianId, claimType }: { orgId: string | undefined; technicianId: string; claimType: "petrol" | "maintenance" }) {
  const { t } = useTranslation()
  const submit = useSubmitExpenseClaim()
  const galleryRef = useRef<HTMLInputElement>(null)
  const cameraRef = useRef<HTMLInputElement>(null)
  const [amount, setAmount] = useState("")
  const [uploading, setUploading] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [done, setDone] = useState(false)

  async function handleFile(file: File) {
    if (!orgId || !amount) {
      setError(t("technician.expenses.enterAmountFirst"))
      return
    }
    setUploading(true)
    setError(null)
    try {
      const path = await uploadExpenseClaimPhoto(orgId, technicianId, file)
      await submit.mutateAsync({ orgId, claimType, submittedAmount: Number(amount), billPhotoPath: path, period: new Date().toISOString().slice(0, 10) })
      setDone(true)
      setAmount("")
    } catch (e) {
      // Failed save keeps `amount` as entered (only cleared above, on success) — the
      // message below tells the technician that explicitly instead of leaving it implicit.
      setError(isNotYetAvailableError(e) ? t("technician.expenses.notAvailableYet") : t("common.actionFailed"))
    } finally {
      setUploading(false)
    }
  }

  function onChange(e: React.ChangeEvent<HTMLInputElement>) {
    const file = e.target.files?.[0]
    if (file) handleFile(file)
    e.target.value = ""
  }

  return (
    <Card className="gap-2.5">
      <p className="text-sm font-semibold text-text">{t(`technician.expenses.claimTypeValues.${claimType}`)}</p>
      {done ? (
        <p className="flex items-center gap-1.5 rounded-xl bg-success/10 px-3.5 py-2.5 text-sm text-success">
          <CheckCircle2 className="size-4" /> {t("technician.expenses.submitted")}
        </p>
      ) : (
        <>
          <div className="space-y-1">
            <Label htmlFor={`amount-${claimType}`}>{t("technician.expenses.amount")}</Label>
            <Input id={`amount-${claimType}`} type="number" min={0} step="0.5" value={amount} onChange={(e) => setAmount(e.target.value)} />
          </div>
          <div className="flex flex-wrap gap-2">
            <input ref={galleryRef} type="file" accept="image/*" className="hidden" onChange={onChange} />
            <input ref={cameraRef} type="file" accept="image/*" capture="environment" className="hidden" onChange={onChange} />
            <Button type="button" variant="outline" size="sm" disabled={uploading} onClick={() => galleryRef.current?.click()}>
              {uploading ? <Loader2 className="size-3.5 animate-spin" /> : <ImagePlus className="size-3.5" />}
              {t("technician.expenses.uploadFromGallery")}
            </Button>
            <Button type="button" variant="outline" size="sm" disabled={uploading} onClick={() => cameraRef.current?.click()}>
              {uploading ? <Loader2 className="size-3.5 animate-spin" /> : <Camera className="size-3.5" />}
              {t("technician.expenses.takePhoto")}
            </Button>
          </div>
        </>
      )}
      {error ? (
        <div className="space-y-1">
          <p className="flex items-center gap-1.5 text-xs text-danger">
            <TriangleAlert className="size-3.5 shrink-0" /> {error}
          </p>
          <p className="text-xs text-text-muted">{t("technician.expenses.valuesKept")}</p>
        </div>
      ) : null}
    </Card>
  )
}

function KmLogForm({ orgId, technicianId }: { orgId: string | undefined; technicianId: string }) {
  const { t } = useTranslation()
  const addEntry = useAddKmLogEntry()
  const monthlySum = useKmLogMonthlySum(orgId, technicianId, new Date().toISOString().slice(0, 7) + "-01")
  const [entryDate, setEntryDate] = useState(new Date().toISOString().slice(0, 10))
  const [km, setKm] = useState("")
  const [done, setDone] = useState(false)
  const [saveError, setSaveError] = useState<string | null>(null)

  async function submit() {
    if (!orgId || !entryDate || !km) return
    setSaveError(null)
    try {
      await addEntry.mutateAsync({ org_id: orgId, technician_id: technicianId, entry_date: entryDate, km: Number(km), note: null })
      // `km` is only cleared here, on success — a failed save leaves it as entered.
      setKm("")
      setDone(true)
      setTimeout(() => setDone(false), 2000)
    } catch (e) {
      setSaveError(isNotYetAvailableError(e) ? t("technician.expenses.notAvailableYet") : t("common.actionFailed"))
    }
  }

  return (
    <Card className="gap-2.5">
      <p className="text-sm font-semibold text-text">{t("technician.expenses.kmLog.title")}</p>
      {monthlySum.isLoading ? (
        <p className="text-xs text-text-muted">{t("common.loading")}</p>
      ) : monthlySum.isError ? (
        <InlineErrorState
          message={isNotYetAvailableError(monthlySum.error) ? t("technician.expenses.notAvailableYet") : t("technician.expenses.kmLog.monthlySumFailed")}
          onRetry={() => monthlySum.refetch()}
          retryLabel={t("common.retry")}
          className="py-2"
        />
      ) : (
        <p className="text-xs text-text-muted">{t("technician.expenses.kmLog.monthlySum", { km: monthlySum.data ?? 0 })}</p>
      )}
      <div className="grid grid-cols-2 gap-3">
        <div className="space-y-1">
          <Label>{t("technician.expenses.kmLog.date")}</Label>
          <DatePicker value={entryDate} onChange={setEntryDate} />
        </div>
        <div className="space-y-1">
          <Label htmlFor="tech-km">{t("technician.expenses.kmLog.km")}</Label>
          <Input id="tech-km" type="number" min={0} step="0.1" value={km} onChange={(e) => setKm(e.target.value)} />
        </div>
      </div>
      <Button type="button" size="sm" disabled={!km || addEntry.isPending} onClick={submit}>
        {done ? <CheckCircle2 className="size-3.5" /> : null}
        {t("technician.expenses.kmLog.save")}
      </Button>
      {saveError ? (
        <div className="space-y-1">
          <p className="flex items-center gap-1.5 text-xs text-danger">
            <TriangleAlert className="size-3.5 shrink-0" /> {saveError}
          </p>
          <p className="text-xs text-text-muted">{t("technician.expenses.valuesKept")}</p>
        </div>
      ) : null}
    </Card>
  )
}
