import { useRef, useState } from "react"
import { useTranslation } from "react-i18next"
import { Camera, CheckCircle2, ImagePlus, Loader2, TriangleAlert } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { getCameraPermissionState } from "@/lib/offline/cameraPermission"

/**
 * Task 2 — after a UPI payment is confirmed, the technician must attach
 * proof (screenshot from their gallery, or a fresh camera photo of the
 * customer's payment screen) before the visit can be completed. Two
 * distinct file inputs rather than one: a plain `accept="image/*"` input
 * opens the gallery/file picker (screenshot), while `capture="environment"`
 * forces the camera directly (see PhotoCapture.tsx for the same
 * `capture` mechanism used elsewhere in this app).
 *
 * Reviewer decision 2026-10-27: an earlier pass on this branch (Item 9,
 * camera-only capture) removed the gallery input here. That removal has
 * been reverted — this screen must keep BOTH options until the client
 * decides otherwise — while keeping the camera-permission-denied handling
 * that same pass added.
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
            <input ref={galleryRef} type="file" accept="image/*" className="hidden" onChange={handleChange} />
            <input ref={cameraRef} type="file" accept="image/*" capture="environment" className="hidden" onChange={handleChange} />
            <Button type="button" variant="outline" size="sm" disabled={uploading} onClick={() => galleryRef.current?.click()}>
              {uploading ? <Loader2 className="size-3.5 animate-spin" /> : <ImagePlus className="size-3.5" />}
              {t("technician.onsite.paymentProof.uploadScreenshot")}
            </Button>
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
