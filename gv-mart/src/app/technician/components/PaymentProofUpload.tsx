import { useRef, useState } from "react"
import { useTranslation } from "react-i18next"
import { Camera, CheckCircle2, Loader2, TriangleAlert } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { getCameraPermissionState } from "@/lib/offline/cameraPermission"

/**
 * Task 2 — after a UPI payment is confirmed, the technician must attach
 * proof (a fresh camera photo of the customer's payment screen) before the
 * visit can be completed.
 *
 * Item 9 (camera-only capture) — this used to also offer a plain
 * `accept="image/*"` input that opened the gallery/file picker (for a
 * pre-existing screenshot). That gallery path has been removed so every
 * technician photo-upload flow in the app is camera-only; `capture="environment"`
 * is now the only input (see PhotoCapture.tsx for the same mechanism used
 * elsewhere). Flagged to the owner: this does remove the ability to attach
 * an already-taken screenshot as proof — see the build report.
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
  const cameraRef = useRef<HTMLInputElement>(null)
  const [transactionReference, setTransactionReference] = useState("")
  const [permissionError, setPermissionError] = useState<string | null>(null)

  function handleChange(e: React.ChangeEvent<HTMLInputElement>) {
    const file = e.target.files?.[0]
    if (file) {
      setPermissionError(null)
      onSelectFile(file, transactionReference)
    } else {
      void handleNoFile()
    }
    e.target.value = ""
  }

  async function openCamera() {
    setPermissionError(null)
    const permission = await getCameraPermissionState()
    if (permission === "denied") {
      setPermissionError(t("technician.photo.permissionDenied"))
      return
    }
    cameraRef.current?.click()
  }

  async function handleNoFile() {
    const permission = await getCameraPermissionState()
    if (permission === "denied") setPermissionError(t("technician.photo.permissionDenied"))
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
            <input ref={cameraRef} type="file" accept="image/*" capture="environment" className="hidden" onChange={handleChange} />
            <Button type="button" variant="outline" size="sm" disabled={uploading} onClick={() => void openCamera()}>
              {uploading ? <Loader2 className="size-3.5 animate-spin" /> : <Camera className="size-3.5" />}
              {t("technician.onsite.paymentProof.capturePhoto")}
            </Button>
          </div>
        </>
      )}
      {permissionError || error ? (
        <p className="flex items-center gap-1.5 text-xs text-danger">
          <TriangleAlert className="size-3.5 shrink-0" /> {permissionError || error}
        </p>
      ) : null}
    </div>
  )
}
