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

const MAX_IMAGE_DIMENSION = 800

/** Downscales an image to fit within maxDim x maxDim (aspect ratio preserved) — a no-op if it's already smaller. Keeps captured/uploaded photos (and their base64 storage footprint) from ballooning to full camera resolution. */
export async function resizeImage(sourceDataUrl: string, maxDim: number = MAX_IMAGE_DIMENSION): Promise<string> {
  const img = await loadImage(sourceDataUrl)
  const scale = Math.min(1, maxDim / img.naturalWidth, maxDim / img.naturalHeight)
  if (scale === 1) return sourceDataUrl

  const canvas = document.createElement("canvas")
  canvas.width = Math.round(img.naturalWidth * scale)
  canvas.height = Math.round(img.naturalHeight * scale)
  const ctx = canvas.getContext("2d")
  if (!ctx) return sourceDataUrl
  ctx.drawImage(img, 0, 0, canvas.width, canvas.height)
  return canvas.toDataURL("image/jpeg", 0.85)
}

/**
 * Overlays a geotag + timestamp watermark onto a captured photo (TECH-07
 * before/after images: "geotag+timestamp watermark"). Draws a translucent
 * bar across the bottom of the image with lat/lng + local timestamp. Runs
 * entirely in-canvas so it works offline; returns a new data URL.
 */
export async function watermarkImage(sourceDataUrl: string, geo: GeoPoint | null, capturedAt: Date): Promise<string> {
  const resized = await resizeImage(sourceDataUrl)
  const img = await loadImage(resized)
  const canvas = document.createElement("canvas")
  canvas.width = img.naturalWidth
  canvas.height = img.naturalHeight
  const ctx = canvas.getContext("2d")
  if (!ctx) return resized

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
