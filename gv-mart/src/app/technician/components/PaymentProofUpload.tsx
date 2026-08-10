import { useRef, useState } from "react"
import { useTranslation } from "react-i18next"
import { Camera, CheckCircle2, ImagePlus, Loader2, TriangleAlert } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"

/**
 * Task 2 — after a UPI payment is confirmed, the technician must attach
 * proof (screenshot from their gallery, or a fresh camera photo of the
 * customer's payment screen) before the visit can be completed. Two
 * distinct file inputs rather than one: a plain `accept="image/*"` input
 * opens the gallery/file picker (screenshot), while `capture="environment"`
 * forces the camera directly (see PhotoCapture.tsx for the same
 * `capture` mechanism used elsewhere in this app).
 */
export function PaymentProofUpload({
  uploaded,
  uploading,
  error,
  onSelectFile,
}: {
  uploaded: boolean
  uploading: boolean
  error: string | null
  onSelectFile: (file: File, transactionReference: string) => void
}) {
  const { t } = useTranslation()
  const galleryRef = useRef<HTMLInputElement>(null)
  const cameraRef = useRef<HTMLInputElement>(null)
  const [transactionReference, setTransactionReference] = useState("")

  function handleChange(e: React.ChangeEvent<HTMLInputElement>) {
    const file = e.target.files?.[0]
    if (file) onSelectFile(file, transactionReference)
    e.target.value = ""
  }

  return (
    <div className="space-y-2 rounded-xl border border-border bg-surface-alt/40 px-3.5 py-3">
      <p className="text-sm font-semibold text-text">{t("technician.onsite.paymentProof.title")}</p>
      <p className="text-xs text-text-muted">{t("technician.onsite.paymentProof.hint")}</p>

      {uploaded ? (
        <p className="flex items-center gap-1.5 rounded-xl bg-success/10 px-3.5 py-2.5 text-sm text-success">
          <CheckCircle2 className="size-4" /> {t("technician.onsite.paymentProof.uploaded")}
        </p>
      ) : (
        <>
          <div className="space-y-1.5">
            <Label htmlFor="paymentProofTxnRef">{t("technician.onsite.paymentProof.transactionReference")}</Label>
            <Input
              id="paymentProofTxnRef"
              value={transactionReference}
              onChange={(e) => setTransactionReference(e.target.value)}
              placeholder={t("technician.onsite.paymentProof.transactionReferencePlaceholder")}
            />
          </div>
          <div className="flex flex-wrap gap-2">
            <input ref={galleryRef} type="file" accept="image/*" className="hidden" onChange={handleChange} />
            <input ref={cameraRef} type="file" accept="image/*" capture="environment" className="hidden" onChange={handleChange} />
            <Button type="button" variant="outline" size="sm" disabled={uploading} onClick={() => galleryRef.current?.click()}>
              {uploading ? <Loader2 className="size-3.5 animate-spin" /> : <ImagePlus className="size-3.5" />}
              {t("technician.onsite.paymentProof.uploadScreenshot")}
            </Button>
            <Button type="button" variant="outline" size="sm" disabled={uploading} onClick={() => cameraRef.current?.click()}>
              {uploading ? <Loader2 className="size-3.5 animate-spin" /> : <Camera className="size-3.5" />}
              {t("technician.onsite.paymentProof.capturePhoto")}
            </Button>
          </div>
        </>
      )}
      {error ? (
        <p className="flex items-center gap-1.5 text-xs text-danger">
          <TriangleAlert className="size-3.5 shrink-0" /> {error}
        </p>
      ) : null}
    </div>
  )
}
