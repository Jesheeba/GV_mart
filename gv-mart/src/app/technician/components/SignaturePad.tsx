import { useRef, useState, type PointerEvent as ReactPointerEvent } from "react"
import { useTranslation } from "react-i18next"
import { Eraser } from "lucide-react"
import { Button } from "@/components/ui/button"
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
  const [hasStrokes, setHasStrokes] = useState(false)

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
    ctx.strokeStyle = "#1A1A1A"
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

  function clear() {
    const canvas = canvasRef.current
    const ctx = getCtx()
    if (!canvas || !ctx) return
    ctx.clearRect(0, 0, canvas.width, canvas.height)
    setHasStrokes(false)
    onChange(null)
  }

  return (
    <div className="space-y-2">
      <canvas
        ref={canvasRef}
        width={600}
        height={height * 2}
        style={{ height }}
        className={cn(
          "w-full touch-none rounded-xl border border-border bg-surface-alt",
          disabled && "cursor-not-allowed opacity-60"
        )}
        onPointerDown={handlePointerDown}
        onPointerMove={handlePointerMove}
        onPointerUp={handlePointerUp}
        onPointerLeave={handlePointerUp}
      />
      <div className="flex items-center justify-between">
        <p className="text-xs text-text-muted">{hasStrokes ? t("technician.signature.captured") : t("technician.signature.placeholder")}</p>
        <Button type="button" variant="outline" size="xs" disabled={disabled || !hasStrokes} onClick={clear}>
          <Eraser className="size-3.5" />
          {t("technician.signature.clear")}
        </Button>
      </div>
    </div>
  )
}
