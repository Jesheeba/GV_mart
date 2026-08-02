import { useId, useRef, useState, type PointerEvent as ReactPointerEvent } from "react"
import { useTranslation } from "react-i18next"
import { Eraser, Keyboard } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { Dialog, DialogContent, DialogDescription, DialogTitle } from "@/components/ui/dialog"
import { cn } from "@/lib/utils"

/**
 * Plain canvas + pointer events signature capture (TECH-02, TECH-07 step 9).
 * No dependency — a signature pad is a handful of canvas calls and doesn't
 * warrant pulling in a library (see report Integration Notes).
 */
export function SignaturePad({
  onChange,
  disabled,
  height = 160,
}: {
  onChange: (dataUrl: string | null) => void
  disabled?: boolean
  height?: number
}) {
  const { t } = useTranslation()
  const canvasRef = useRef<HTMLCanvasElement>(null)
  const drawing = useRef(false)
  const strokeColor = useRef("#1a1a1a")
  const [hasStrokes, setHasStrokes] = useState(false)
  const [confirmClearOpen, setConfirmClearOpen] = useState(false)
  const [typedMode, setTypedMode] = useState(false)
  const [typedName, setTypedName] = useState("")
  const statusId = useId()

  function getCtx() {
    const canvas = canvasRef.current
    if (!canvas) return null
    return canvas.getContext("2d")
  }

  function pointFromEvent(e: ReactPointerEvent<HTMLCanvasElement>) {
    const canvas = canvasRef.current!
    const rect = canvas.getBoundingClientRect()
    const scaleX = canvas.width / rect.width
    const scaleY = canvas.height / rect.height
    return { x: (e.clientX - rect.left) * scaleX, y: (e.clientY - rect.top) * scaleY }
  }

  function handlePointerDown(e: ReactPointerEvent<HTMLCanvasElement>) {
    if (disabled) return
    const ctx = getCtx()
    if (!ctx) return
    const canvas = canvasRef.current
    if (canvas) {
      strokeColor.current = getComputedStyle(canvas).getPropertyValue("--text").trim() || "#1a1a1a"
    }
    drawing.current = true
    const { x, y } = pointFromEvent(e)
    ctx.beginPath()
    ctx.moveTo(x, y)
    canvasRef.current?.setPointerCapture(e.pointerId)
  }

  function handlePointerMove(e: ReactPointerEvent<HTMLCanvasElement>) {
    if (!drawing.current || disabled) return
    const ctx = getCtx()
    if (!ctx) return
    const { x, y } = pointFromEvent(e)
    ctx.lineWidth = 2.5
    ctx.lineCap = "round"
    ctx.strokeStyle = strokeColor.current
    ctx.lineTo(x, y)
    ctx.stroke()
    setHasStrokes(true)
  }

  function handlePointerUp() {
    if (!drawing.current) return
    drawing.current = false
    const canvas = canvasRef.current
    if (canvas) onChange(canvas.toDataURL("image/png"))
  }

  function wipeCanvas() {
    const canvas = canvasRef.current
    const ctx = getCtx()
    if (!canvas || !ctx) return
    ctx.clearRect(0, 0, canvas.width, canvas.height)
  }

  function clear() {
    wipeCanvas()
    setHasStrokes(false)
    setTypedName("")
    onChange(null)
  }

  function requestClear() {
    if (hasStrokes) {
      setConfirmClearOpen(true)
      return
    }
    clear()
  }

  function confirmClear() {
    clear()
    setConfirmClearOpen(false)
  }

  function commitTypedSignature() {
    const canvas = canvasRef.current
    const ctx = getCtx()
    if (!canvas || !ctx || !typedName.trim()) return
    wipeCanvas()
    ctx.fillStyle = getComputedStyle(canvas).getPropertyValue("--text").trim() || "#1a1a1a"
    ctx.font = "italic 600 40px var(--font-sans), sans-serif"
    ctx.textBaseline = "middle"
    ctx.fillText(typedName.trim(), 24, canvas.height / 2)
    setHasStrokes(true)
    onChange(canvas.toDataURL("image/png"))
  }

  return (
    <div className="space-y-2">
      <canvas
        ref={canvasRef}
        width={600}
        height={height * 2}
        style={{ height }}
        role="img"
        aria-label={t("technician.signature.canvasLabel")}
        aria-describedby={statusId}
        className={cn(
          "w-full touch-none rounded-xl border border-border bg-surface-alt",
          disabled && "cursor-not-allowed opacity-60"
        )}
        onPointerDown={handlePointerDown}
        onPointerMove={handlePointerMove}
        onPointerUp={handlePointerUp}
        onPointerLeave={handlePointerUp}
      />
      <div className="flex items-center justify-between gap-2">
        <p id={statusId} className="text-xs text-text-muted">
          {hasStrokes ? t("technician.signature.captured") : t("technician.signature.placeholder")}
        </p>
        <div className="flex items-center gap-1.5">
          <Button type="button" variant="ghost" size="xs" disabled={disabled} onClick={() => setTypedMode((v) => !v)}>
            <Keyboard className="size-3.5" />
            {t("technician.signature.typeInstead")}
          </Button>
          <Button type="button" variant="outline" size="xs" disabled={disabled || !hasStrokes} onClick={requestClear}>
            <Eraser className="size-3.5" />
            {t("technician.signature.clear")}
          </Button>
        </div>
      </div>
      {typedMode ? (
        <div className="flex items-center gap-2">
          <Input
            value={typedName}
            onChange={(e) => setTypedName(e.target.value)}
            placeholder={t("technician.signature.typedPlaceholder")}
            aria-label={t("technician.signature.typedPlaceholder")}
            disabled={disabled}
          />
          <Button
            type="button"
            variant="outline"
            size="xs"
            disabled={disabled || !typedName.trim()}
            onClick={commitTypedSignature}
          >
            {t("technician.signature.typedApply")}
          </Button>
        </div>
      ) : null}
      <Dialog open={confirmClearOpen} onOpenChange={setConfirmClearOpen}>
        <DialogContent>
          <DialogTitle>{t("technician.signature.clearConfirmTitle")}</DialogTitle>
          <DialogDescription>{t("technician.signature.clearConfirmBody")}</DialogDescription>
          <div className="flex justify-end gap-2">
            <Button type="button" variant="outline" size="sm" onClick={() => setConfirmClearOpen(false)}>
              {t("technician.signature.clearConfirmCancel")}
            </Button>
            <Button type="button" variant="destructive" size="sm" onClick={confirmClear}>
              {t("technician.signature.clearConfirmAction")}
            </Button>
          </div>
        </DialogContent>
      </Dialog>
    </div>
  )
}
