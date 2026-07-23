import { useRef, useState } from "react"
import { useTranslation } from "react-i18next"
import { Mic, Square, Trash2, TriangleAlert, Upload } from "lucide-react"
import { Button } from "@/components/ui/button"

function blobToDataUrl(blob: Blob): Promise<string> {
  return new Promise((resolve, reject) => {
    const reader = new FileReader()
    reader.onload = () => resolve(reader.result as string)
    reader.onerror = () => reject(reader.error)
    reader.readAsDataURL(blob)
  })
}

/**
 * Build Order A3 — optional on-site voice note, recorded alongside the
 * existing text note. Same "no extra dependency, native browser API" choice
 * as PhotoCapture (native file input) and SignaturePad (plain canvas):
 * `MediaRecorder` + `getUserMedia` for in-app recording, with a plain
 * `<input type=file accept="audio/*">` fallback for devices/browsers where
 * mic capture isn't available or permission is denied — mirrors
 * PhotoCapture's native-capture-input approach. Stored as a data: URL, same
 * convention as every other captured media in this app (no Supabase Storage
 * bucket is used anywhere — see 20260724110000_service_visit_voice_notes.sql).
 */
export function VoiceNoteRecorder({
  label,
  dataUrl,
  onChange,
  disabled,
}: {
  label: string
  dataUrl: string | null
  onChange: (dataUrl: string | null) => void
  disabled?: boolean
}) {
  const { t } = useTranslation()
  const fileInputRef = useRef<HTMLInputElement>(null)
  const mediaRecorderRef = useRef<MediaRecorder | null>(null)
  const chunksRef = useRef<Blob[]>([])
  const streamRef = useRef<MediaStream | null>(null)
  const [recording, setRecording] = useState(false)
  const [error, setError] = useState<string | null>(null)

  function stopStream() {
    streamRef.current?.getTracks().forEach((tr) => tr.stop())
    streamRef.current = null
  }

  async function startRecording() {
    setError(null)
    if (!navigator.mediaDevices?.getUserMedia || typeof MediaRecorder === "undefined") {
      setError(t("technician.voiceNote.unsupported"))
      return
    }
    try {
      const stream = await navigator.mediaDevices.getUserMedia({ audio: true })
      streamRef.current = stream
      chunksRef.current = []
      const recorder = new MediaRecorder(stream)
      recorder.ondataavailable = (e) => {
        if (e.data.size > 0) chunksRef.current.push(e.data)
      }
      recorder.onstop = () => {
        stopStream()
        const blob = new Blob(chunksRef.current, { type: recorder.mimeType || "audio/webm" })
        void blobToDataUrl(blob).then(onChange)
      }
      mediaRecorderRef.current = recorder
      recorder.start()
      setRecording(true)
    } catch {
      setError(t("technician.voiceNote.permissionDenied"))
    }
  }

  function stopRecording() {
    mediaRecorderRef.current?.stop()
    mediaRecorderRef.current = null
    setRecording(false)
  }

  async function handleFile(file: File) {
    setError(null)
    const url = await blobToDataUrl(file)
    onChange(url)
  }

  function clear() {
    onChange(null)
    setError(null)
  }

  return (
    <div className="space-y-2">
      <p className="px-1 text-sm font-medium text-text">{label}</p>
      {dataUrl ? (
        <audio controls src={dataUrl} className="w-full" />
      ) : (
        <div className="flex aspect-[4/1] w-full items-center justify-center rounded-xl border border-dashed border-border bg-surface-alt text-text-muted">
          <Mic className="size-6" />
        </div>
      )}
      {error ? (
        <p className="flex items-center gap-1.5 text-xs text-danger">
          <TriangleAlert className="size-3.5 shrink-0" /> {error}
        </p>
      ) : null}
      <input
        ref={fileInputRef}
        type="file"
        accept="audio/*"
        className="hidden"
        onChange={(e) => {
          const file = e.target.files?.[0]
          if (file) void handleFile(file)
          e.target.value = ""
        }}
      />
      <div className="flex flex-wrap gap-2">
        {recording ? (
          <Button type="button" variant="destructive" size="sm" onClick={stopRecording}>
            <Square className="size-3.5" />
            {t("technician.voiceNote.stop")}
          </Button>
        ) : (
          <Button type="button" variant="outline" size="sm" disabled={disabled} onClick={startRecording}>
            <Mic className="size-3.5" />
            {dataUrl ? t("technician.voiceNote.rerecord") : t("technician.voiceNote.record")}
          </Button>
        )}
        <Button type="button" variant="outline" size="sm" disabled={disabled || recording} onClick={() => fileInputRef.current?.click()}>
          <Upload className="size-3.5" />
          {t("technician.voiceNote.upload")}
        </Button>
        {dataUrl ? (
          <Button type="button" variant="ghost" size="sm" disabled={disabled || recording} onClick={clear}>
            <Trash2 className="size-3.5 text-danger" />
            {t("technician.voiceNote.clear")}
          </Button>
        ) : null}
      </div>
    </div>
  )
}
