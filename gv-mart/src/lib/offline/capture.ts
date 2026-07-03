import type { GeoPoint } from "./geo"

/** Reads a File (from an <input type=file capture> or canvas signature) into a data URL. */
export function fileToDataUrl(file: File): Promise<string> {
  return new Promise((resolve, reject) => {
    const reader = new FileReader()
    reader.onload = () => resolve(reader.result as string)
    reader.onerror = () => reject(reader.error)
    reader.readAsDataURL(file)
  })
}

function loadImage(src: string): Promise<HTMLImageElement> {
  return new Promise((resolve, reject) => {
    const img = new Image()
    img.onload = () => resolve(img)
    img.onerror = () => reject(new Error("image_load_failed"))
    img.src = src
  })
}

/**
 * Overlays a geotag + timestamp watermark onto a captured photo (TECH-07
 * before/after images: "geotag+timestamp watermark"). Draws a translucent
 * bar across the bottom of the image with lat/lng + local timestamp. Runs
 * entirely in-canvas so it works offline; returns a new data URL.
 */
export async function watermarkImage(sourceDataUrl: string, geo: GeoPoint | null, capturedAt: Date): Promise<string> {
  const img = await loadImage(sourceDataUrl)
  const canvas = document.createElement("canvas")
  canvas.width = img.naturalWidth
  canvas.height = img.naturalHeight
  const ctx = canvas.getContext("2d")
  if (!ctx) return sourceDataUrl

  ctx.drawImage(img, 0, 0)

  const barHeight = Math.max(48, Math.round(canvas.height * 0.08))
  ctx.fillStyle = "rgba(0, 0, 0, 0.55)"
  ctx.fillRect(0, canvas.height - barHeight, canvas.width, barHeight)

  const fontSize = Math.max(14, Math.round(barHeight * 0.32))
  ctx.fillStyle = "#ffffff"
  ctx.font = `${fontSize}px sans-serif`
  ctx.textBaseline = "middle"

  const geoText = geo ? `${geo.lat.toFixed(6)}, ${geo.lng.toFixed(6)}` : "Location unavailable"
  const timeText = capturedAt.toLocaleString("en-IN", { timeZone: "Asia/Kolkata", hour12: true })

  const padding = Math.round(fontSize * 0.6)
  ctx.fillText(geoText, padding, canvas.height - barHeight + barHeight * 0.35)
  ctx.fillText(timeText, padding, canvas.height - barHeight + barHeight * 0.75)

  return canvas.toDataURL("image/jpeg", 0.85)
}

/** Captures the current position (best-effort) and produces a watermarked photo from a File. Never throws on missing geolocation — falls back to "Location unavailable" in the overlay per offline-first requirements. */
export async function captureWatermarkedPhoto(file: File, geo: GeoPoint | null): Promise<{ dataUrl: string; capturedAt: string; geo: GeoPoint | null }> {
  const raw = await fileToDataUrl(file)
  const capturedAt = new Date()
  const dataUrl = await watermarkImage(raw, geo, capturedAt)
  return { dataUrl, capturedAt: capturedAt.toISOString(), geo }
}
