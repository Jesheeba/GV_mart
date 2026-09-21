import { useState } from "react"
import { useTranslation } from "react-i18next"
import { FileText, Loader2 } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Label } from "@/components/ui/label"
import { technicianDocumentSignedUrl, uploadTechnicianDocument } from "@/services/technicianDocuments"

/**
 * Item 1 (2026-09-21) — shared Aadhar/Driving Licence upload control, used by
 * both TechniciansListPage's Add Technician form and TechnicianDetailPage's
 * edit panel. Uploads straight to the private technician-documents bucket as
 * soon as a file is picked (not deferred to form submit) and reports the
 * resulting storage_path to the caller via onUploaded — the caller just
 * carries that string in its own create/edit payload. The document is never
 * rendered inline; "View" fetches a short-lived signed URL on click.
 */
export function TechnicianDocumentUpload({
  label,
  orgId,
  existingPath,
  onUploaded,
}: {
  label: string
  orgId: string | undefined
  existingPath?: string | null
  onUploaded: (path: string) => void
}) {
  const { t } = useTranslation()
  const [busy, setBusy] = useState(false)
  const [viewing, setViewing] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [pendingUpload, setPendingUpload] = useState(false)

  async function handleFile(file: File | undefined) {
    if (!file || !orgId) return
    setBusy(true)
    setError(null)
    try {
      const path = await uploadTechnicianDocument(orgId, file)
      onUploaded(path)
      setPendingUpload(true)
    } catch (e) {
      setError((e as Error).message)
    } finally {
      setBusy(false)
    }
  }

  async function handleView() {
    if (!existingPath) return
    setViewing(true)
    setError(null)
    try {
      const url = await technicianDocumentSignedUrl(existingPath)
      window.open(url, "_blank", "noopener,noreferrer")
    } catch (e) {
      setError((e as Error).message)
    } finally {
      setViewing(false)
    }
  }

  const hasDocument = pendingUpload || !!existingPath

  return (
    <div className="space-y-1">
      <Label>{label}</Label>
      <div className="flex items-center gap-2">
        <label className="flex h-11 flex-1 cursor-pointer items-center justify-center gap-2 rounded-xl border border-dashed border-border bg-surface-alt text-xs font-semibold text-text-muted hover:bg-surface">
          {busy ? <Loader2 className="size-3.5 animate-spin" /> : <FileText className="size-3.5" />}
          {hasDocument ? t("technicians.list.fields.documentReplace") : t("technicians.list.fields.documentUpload")}
          <input type="file" accept="image/*" className="hidden" onChange={(e) => handleFile(e.target.files?.[0])} />
        </label>
        {existingPath ? (
          <Button type="button" size="sm" variant="outline" disabled={viewing} onClick={handleView}>
            {viewing ? <Loader2 className="size-3.5 animate-spin" /> : t("technicians.list.fields.documentView")}
          </Button>
        ) : null}
      </div>
      {error ? <p className="text-xs text-danger">{error}</p> : null}
      {pendingUpload ? <p className="text-xs text-success">{t("technicians.list.fields.documentUploaded")}</p> : null}
    </div>
  )
}
