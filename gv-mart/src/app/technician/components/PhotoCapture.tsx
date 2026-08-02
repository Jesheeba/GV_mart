import { useRef, useState } from "react"
import { useTranslation } from "react-i18next"
import { Camera, Loader2, RefreshCcw, TriangleAlert } from "lucide-react"
import { Button } from "@/components/ui/button"
import { captureWatermarkedPhoto } from "@/lib/offline/capture"
import { getCurrentPosition } from "@/lib/offline/geo"

/**
 * `<input type=file accept="image/*" capture="environment">` is the native
 * capture path (works fully offline, no extra permission dance beyond the
 * input itself) — see Integration Notes for why no camera library was added.
 * Captures best-effort geolocation and burns a geotag+timestamp watermark
 * into the photo before handing back a data URL (TECH-07 before/after images).
 */
export function PhotoCapture({
  label,
  dataUrl,
  onCaptured,
  disabled,
}: {
  label: string
  dataUrl: string | null
  onCaptured: (dataUrl: string) => void
  disabled?: boolean
}) {
  const { t } = useTranslation()
  const inputRef = useRef<HTMLInputElement>(null)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)

  async function handleFile(file: File) {
    setBusy(true)
    setError(null)
    try {
      let geo = null
      try {
        geo = await getCurrentPosition()
      } catch {
        geo = null
      }
      const { dataUrl: watermarked } = await captureWatermarkedPhoto(file, geo)
      onCaptured(watermarked)
    } catch {
      setError(t("technician.photo.error"))
    } finally {
      setBusy(false)
    }
  }

  return (
    <div className="space-y-2">
      <p className="px-1 text-sm font-medium text-text">{label}</p>
      {dataUrl ? (
        <img src={dataUrl} alt={label} className="w-full rounded-xl border border-border object-cover" />
      ) : (
        <div className="flex aspect-video w-full items-center justify-center rounded-xl border border-dashed border-border bg-surface-alt text-text-muted">
          <Camera className="size-8" />
        </div>
      )}
      {error ? (
        <p className="flex items-center gap-1.5 text-xs text-danger">
          <TriangleAlert className="size-3.5 shrink-0" /> {error}
        </p>
      ) : null}
      <input
        ref={inputRef}
        type="file"
        accept="image/*"
        capture="environment"
        className="hidden"
        onChange={(e) => {
          const file = e.target.files?.[0]
          if (file) void handleFile(file)
          e.target.value = ""
        }}
      />
      <Button type="button" variant="outline" size="sm" disabled={disabled || busy} onClick={() => inputRef.current?.click()}>
        {busy ? <Loader2 className="size-3.5 animate-spin" /> : dataUrl ? <RefreshCcw className="size-3.5" /> : <Camera className="size-3.5" />}
        {dataUrl ? t("technician.photo.retake") : t("technician.photo.capture")}
      </Button>
    </div>
  )
}
