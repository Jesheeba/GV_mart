"use client"

import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useMemo,
  useRef,
  useState,
  type ReactNode,
} from "react"
import { createPortal } from "react-dom"
import { Locate, Loader2, Minus, Plus } from "lucide-react"
import { cn } from "@/lib/utils"
import { useTheme } from "@/lib/theme/ThemeProvider"

declare global {
  interface Window {
    gm_authFailure?: () => void
  }
}

/**
 * Google Maps JS API-based replacement for the previous MapLibre+MapTiler
 * wrapper. Only the four pieces AddressMapPicker actually uses are
 * implemented (Map, MapControls, MapMarker, MarkerContent) — this file is
 * intentionally narrower than the MapLibre version it replaces, which also
 * exported MapRoute/MapArc/MapGeoJSON/MarkerPopup/MarkerTooltip/MarkerLabel/
 * MapClusterLayer that had no consumers anywhere in the codebase.
 */

// Muted, low-saturation styling close to the Finexy palette (cream
// background, ink-toned labels) — Google's inline JSON styling array, the
// legacy-Marker-compatible equivalent of a custom basemap style.
const FINEXY_MAP_STYLE: google.maps.MapTypeStyle[] = [
  { elementType: "geometry", stylers: [{ color: "#f4f1ec" }] },
  { elementType: "labels.text.fill", stylers: [{ color: "#6b6b63" }] },
  { elementType: "labels.text.stroke", stylers: [{ color: "#f4f1ec" }] },
  { featureType: "road", elementType: "geometry", stylers: [{ color: "#ffffff" }] },
  { featureType: "road", elementType: "geometry.stroke", stylers: [{ color: "#e2ddd2" }] },
  { featureType: "road.arterial", elementType: "geometry", stylers: [{ color: "#fdfbf8" }] },
  { featureType: "water", elementType: "geometry", stylers: [{ color: "#d7ece8" }] },
  { featureType: "poi.park", elementType: "geometry", stylers: [{ color: "#e3ecd8" }] },
  { featureType: "transit", stylers: [{ visibility: "off" }] },
  { featureType: "administrative", elementType: "geometry.stroke", stylers: [{ color: "#d8d3c8" }] },
]

// Dark counterpart of FINEXY_MAP_STYLE, matching the .dark overrides in
// index.css (--bg #14130f, --surface #1e1c17, --surface-alt #262319,
// --text-muted #a39d8c) so the map reads as part of the dark UI instead of
// a bright rectangle punched into it.
const FINEXY_MAP_STYLE_DARK: google.maps.MapTypeStyle[] = [
  { elementType: "geometry", stylers: [{ color: "#14130f" }] },
  { elementType: "labels.text.fill", stylers: [{ color: "#a39d8c" }] },
  { elementType: "labels.text.stroke", stylers: [{ color: "#14130f" }] },
  { featureType: "road", elementType: "geometry", stylers: [{ color: "#1e1c17" }] },
  { featureType: "road", elementType: "geometry.stroke", stylers: [{ color: "#262319" }] },
  { featureType: "road.arterial", elementType: "geometry", stylers: [{ color: "#211f19" }] },
  { featureType: "water", elementType: "geometry", stylers: [{ color: "#132420" }] },
  { featureType: "poi.park", elementType: "geometry", stylers: [{ color: "#1a2317" }] },
  { featureType: "transit", stylers: [{ visibility: "off" }] },
  { featureType: "administrative", elementType: "geometry.stroke", stylers: [{ color: "#332f22" }] },
]

// Premium Live Tracking's map (redesign 2026-08-05) — customer feedback on
// the earlier "route-focused" style (all labels/POIs/roads scrubbed to
// near-white) was that it read as broken/blank rather than a real map, even
// though it was the genuine Google Maps JS API underneath. Reverted to
// Google's own default road-map styling (empty `styles` array = no
// override) so street names, road colors, and landmarks are immediately
// recognizable as "the real Google Maps" — still wrapped in the app's own
// rounded-card chrome and orange-accent markers/route line.
const STANDARD_MAP_STYLE: google.maps.MapTypeStyle[] = []

let mapsLoadPromise: Promise<void> | null = null

/** Loads the Maps JavaScript API exactly once per page, however many <Map>s mount/unmount. */
function loadGoogleMaps(apiKey: string): Promise<void> {
  if (typeof window !== "undefined" && window.google?.maps?.Map) {
    return Promise.resolve()
  }
  if (!mapsLoadPromise) {
    mapsLoadPromise = new Promise((resolve, reject) => {
      const existing = document.getElementById("gv-mart-google-maps") as HTMLScriptElement | null
      if (existing) {
        existing.addEventListener("load", () => resolve())
        existing.addEventListener("error", () => reject(new Error("Failed to load Google Maps")))
        return
      }
      const script = document.createElement("script")
      script.id = "gv-mart-google-maps"
      // Deliberately NOT `&loading=async`: that flag defers populating
      // `google.maps.*` until after its own internal async bootstrap
      // finishes, so the script's `load` event can fire before
      // `google.maps.Map` actually exists (a real, intermittent bug found
      // in testing — `new google.maps.Map(...)` threw with no console
      // output because the catch below swallowed it silently). Without the
      // flag, `load` firing does guarantee `google.maps.*` is ready — at
      // the documented cost of one harmless perf-suggestion console
      // message, not worth the race condition for this single small widget.
      script.src = `https://maps.googleapis.com/maps/api/js?key=${encodeURIComponent(apiKey)}`
      script.async = true
      script.onload = () => resolve()
      script.onerror = () => reject(new Error("Failed to load Google Maps"))
      document.head.appendChild(script)
    })
  }
  return mapsLoadPromise
}

/** Reproduces lucide-react's `<MapPin fill-accent text-ink>` glyph as a Google Marker icon (legacy Marker can't host arbitrary DOM/React content). */
const PIN_ICON_URL =
  "data:image/svg+xml;utf8," +
  encodeURIComponent(
    `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="#F5612C" stroke="#1A1A1A" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round">` +
      `<path d="M20 10c0 4.993-5.539 10.193-7.399 11.799a1 1 0 0 1-1.202 0C9.539 20.193 4 14.993 4 10a8 8 0 0 1 16 0"/>` +
      `<circle cx="12" cy="10" r="3"/>` +
      `</svg>`
  )

type MapContextValue = { map: google.maps.Map | null }
const MapContext = createContext<MapContextValue | null>(null)

function useMap() {
  const ctx = useContext(MapContext)
  if (!ctx) throw new Error("useMap must be used within a Map component")
  return ctx
}

type MapViewport = { center: [number, number]; zoom: number }

type MapProps = {
  className?: string
  apiKey: string | undefined
  viewport: MapViewport
  onViewportChange?: (viewport: MapViewport) => void
  onLoadError?: () => void
  /** "standard" selects STANDARD_MAP_STYLE (Google's own default road-map
   * look — Premium Live Tracking) so the map reads unmistakably as real
   * Google Maps. Defaults to the app's muted FINEXY_MAP_STYLE everywhere else. */
  variant?: "default" | "standard"
  children?: ReactNode
}

function DefaultLoader() {
  return (
    <div className="absolute inset-0 z-10 flex items-center justify-center bg-surface-alt/70 backdrop-blur-xs">
      <Loader2 className="size-5 animate-spin text-text-muted" />
    </div>
  )
}

function stylesFor(theme: string, variant: "default" | "standard") {
  if (variant === "standard") return STANDARD_MAP_STYLE
  return theme === "dark" ? FINEXY_MAP_STYLE_DARK : FINEXY_MAP_STYLE
}

function Map({ className, apiKey, viewport, onViewportChange, onLoadError, variant = "default", children }: MapProps) {
  const { theme } = useTheme()
  const containerRef = useRef<HTMLDivElement>(null)
  const [mapInstance, setMapInstance] = useState<google.maps.Map | null>(null)
  const internalUpdateRef = useRef(false)
  const onViewportChangeRef = useRef(onViewportChange)
  onViewportChangeRef.current = onViewportChange
  const onLoadErrorRef = useRef(onLoadError)
  onLoadErrorRef.current = onLoadError
  const themeRef = useRef(theme)
  themeRef.current = theme
  const variantRef = useRef(variant)
  variantRef.current = variant

  useEffect(() => {
    if (!apiKey) return
    let cancelled = false
    // Google's own signal for "the key is missing/invalid/unauthorized for
    // this domain" — distinct from a network failure, since the JS file
    // itself loads fine in that case and only this callback fires.
    window.gm_authFailure = () => {
      console.error("Google Maps auth failure — check API key restrictions/billing in Google Cloud Console")
      if (!cancelled) onLoadErrorRef.current?.()
    }
    loadGoogleMaps(apiKey)
      .then(() => {
        if (cancelled || !containerRef.current) return
        const map = new google.maps.Map(containerRef.current, {
          center: { lat: viewport.center[1], lng: viewport.center[0] },
          zoom: viewport.zoom,
          disableDefaultUI: true,
          gestureHandling: "greedy",
          clickableIcons: false,
          styles: stylesFor(themeRef.current, variantRef.current),
        })
        map.addListener("idle", () => {
          if (internalUpdateRef.current) return
          const center = map.getCenter()
          if (!center) return
          onViewportChangeRef.current?.({ center: [center.lng(), center.lat()], zoom: map.getZoom() ?? viewport.zoom })
        })
        setMapInstance(map)
      })
      .catch((err) => {
        // Logged (not just silently surfaced as the generic error card) so a
        // real failure is diagnosable from the console instead of requiring
        // guesswork — this exact gap is what made the loading=async race
        // above so hard to track down.
        console.error("Failed to initialize Google Maps:", err)
        if (!cancelled) onLoadErrorRef.current?.()
      })
    return () => {
      cancelled = true
      delete window.gm_authFailure
    }
    // Deliberately mount-only: the map is created once per <Map> instance;
    // viewport updates after mount go through the controlled-sync effect
    // below instead of recreating the map.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [apiKey])

  // Sync controlled viewport → map, mirroring the previous MapLibre wrapper's
  // "skip if this change originated from our own idle handler" guard.
  useEffect(() => {
    if (!mapInstance) return
    const current = mapInstance.getCenter()
    const currentZoom = mapInstance.getZoom()
    const [lng, lat] = viewport.center
    if (current && current.lat() === lat && current.lng() === lng && currentZoom === viewport.zoom) return
    internalUpdateRef.current = true
    mapInstance.panTo({ lat, lng })
    mapInstance.setZoom(viewport.zoom)
    const id = window.setTimeout(() => {
      internalUpdateRef.current = false
    }, 0)
    return () => window.clearTimeout(id)
  }, [mapInstance, viewport.center, viewport.zoom])

  // Restyles an already-created map in place when the theme (or variant)
  // changes, instead of tearing the map down and re-running the mount effect above.
  useEffect(() => {
    if (!mapInstance) return
    mapInstance.setOptions({ styles: stylesFor(theme, variant) })
  }, [mapInstance, theme, variant])

  const contextValue = useMemo(() => ({ map: mapInstance }), [mapInstance])

  return (
    <MapContext.Provider value={contextValue}>
      <div className={cn("relative h-full w-full", className)}>
        {/* Google Maps takes direct, imperative ownership of this node's DOM
            subtree once initialized — React must never render children into
            it, or the two reconcilers fight over the same nodes and React
            throws NotFoundError on removeChild the moment state changes. */}
        <div ref={containerRef} className="absolute inset-0" />
        {!mapInstance ? <DefaultLoader /> : null}
        {mapInstance ? children : null}
      </div>
    </MapContext.Provider>
  )
}

/** Small filled circle (vehicle/person indicator) — the admin live-tracking
 * map's alternative to the default location pin, colored per technician
 * status (green/red/neutral) at a glance. */
function dotIconUrl(color: string) {
  return (
    "data:image/svg+xml;utf8," +
    encodeURIComponent(
      `<svg xmlns="http://www.w3.org/2000/svg" width="22" height="22" viewBox="0 0 22 22">` +
        `<circle cx="11" cy="11" r="8" fill="${color}" stroke="#ffffff" stroke-width="2.5"/>` +
        `</svg>`
    )
  )
}

/** A5 — technician route trail: a larger ring-styled marker for an idle
 * spot, deliberately distinct from the small filled dot used for a live
 * technician position (dotIconUrl above) so an idle spot reads as its own
 * pin rather than just another point on the coloured polyline. */
function ringIconUrl(color: string) {
  return (
    "data:image/svg+xml;utf8," +
    encodeURIComponent(
      `<svg xmlns="http://www.w3.org/2000/svg" width="30" height="30" viewBox="0 0 30 30">` +
        `<circle cx="15" cy="15" r="12" fill="${color}" fill-opacity="0.25" stroke="${color}" stroke-width="2.5"/>` +
        `<circle cx="15" cy="15" r="5" fill="${color}" stroke="#ffffff" stroke-width="2"/>` +
        `</svg>`
    )
  )
}

/** Live tracking — customer's own address marker (spec: "house icon, label
 * Your Location"), visually distinct from the default orange pin so the two
 * markers on the tracking map never get confused at a glance. */
function houseIconUrl(color: string) {
  return (
    "data:image/svg+xml;utf8," +
    encodeURIComponent(
      `<svg xmlns="http://www.w3.org/2000/svg" width="30" height="30" viewBox="0 0 24 24">` +
        `<circle cx="12" cy="12" r="11" fill="#ffffff" stroke="${color}" stroke-width="1.5"/>` +
        `<path d="M5 11.5 12 6l7 5.5V18a1 1 0 0 1-1 1h-3.5v-4.5h-5V19H6a1 1 0 0 1-1-1z" fill="${color}"/>` +
        `</svg>`
    )
  )
}

/** Live tracking — technician marker, a heading-aware arrow (spec: "rotate
 * according to heading", "exactly like Uber/Rapido/Google Maps navigation").
 * `technician_locations` has no persisted heading/speed column (see
 * useLiveTracking.ts) — bearing is computed client-side from the last two
 * GPS fixes and baked directly into this SVG's rotate() transform, since a
 * legacy google.maps.Marker's Icon has no rotation property of its own for
 * image icons (that only exists for vector Symbol paths). */
function arrowIconUrl(color: string, rotationDeg: number) {
  return (
    "data:image/svg+xml;utf8," +
    encodeURIComponent(
      `<svg xmlns="http://www.w3.org/2000/svg" width="34" height="34" viewBox="0 0 34 34">` +
        `<circle cx="17" cy="17" r="16" fill="${color}" fill-opacity="0.18"/>` +
        `<g transform="rotate(${rotationDeg} 17 17)">` +
        `<path d="M17 6 L24 24 L17 20 L10 24 Z" fill="${color}" stroke="#ffffff" stroke-width="1.5" stroke-linejoin="round"/>` +
        `</g>` +
        `</svg>`
    )
  )
}

type MapMarkerProps = {
  longitude: number
  latitude: number
  draggable?: boolean
  onDragEnd?: (lngLat: { lng: number; lat: number }) => void
  /** Renders a colored dot instead of the default pin glyph (e.g. live
   * technician status) — omit for the default orange location pin. */
  color?: string
  /** "ring" renders a larger ring-styled marker (see ringIconUrl) instead of
   * the small filled dot — used to mark a route trail's idle spot distinctly
   * from ordinary points/the moving-route polyline. "house" renders the live
   * tracking customer-location marker (houseIconUrl). "arrow" renders the
   * live tracking technician marker, rotated by `rotationDeg` (arrowIconUrl).
   * "dot"/"ring"/"arrow" require `color`; "house" defaults to the accent
   * color if `color` is omitted. */
  variant?: "dot" | "ring" | "house" | "arrow"
  /** Heading in degrees clockwise from north — only meaningful with variant="arrow". */
  rotationDeg?: number
  /** Native browser tooltip on hover (e.g. technician name). */
  title?: string
  /** Kept for call-site compatibility — a legacy google.maps.Marker can't host
   * arbitrary React content, so the themed pin/dot icon is always used
   * regardless of children (see MarkerContent). */
  children?: ReactNode
}

function markerIcon(color: string | undefined, variant: "dot" | "ring" | "house" | "arrow" = "dot", rotationDeg = 0) {
  if (variant === "house") {
    return { url: houseIconUrl(color ?? "#F5612C"), scaledSize: new google.maps.Size(30, 30), anchor: new google.maps.Point(15, 15) }
  }
  if (color && variant === "arrow") {
    return { url: arrowIconUrl(color, rotationDeg), scaledSize: new google.maps.Size(34, 34), anchor: new google.maps.Point(17, 17) }
  }
  if (color && variant === "ring") {
    return { url: ringIconUrl(color), scaledSize: new google.maps.Size(30, 30), anchor: new google.maps.Point(15, 15) }
  }
  return color
    ? { url: dotIconUrl(color), scaledSize: new google.maps.Size(22, 22), anchor: new google.maps.Point(11, 11) }
    : { url: PIN_ICON_URL, scaledSize: new google.maps.Size(28, 28), anchor: new google.maps.Point(14, 24) }
}

function MapMarker({ longitude, latitude, draggable = false, onDragEnd, color, variant = "dot", rotationDeg = 0, title }: MapMarkerProps) {
  const { map } = useMap()
  const [marker, setMarker] = useState<google.maps.Marker | null>(null)
  const onDragEndRef = useRef(onDragEnd)
  onDragEndRef.current = onDragEnd

  useEffect(() => {
    if (!map) return
    const m = new google.maps.Marker({
      map,
      position: { lat: latitude, lng: longitude },
      draggable,
      title,
      icon: markerIcon(color, variant, rotationDeg),
      zIndex: variant === "arrow" ? 20 : undefined,
    })
    m.addListener("dragend", () => {
      const pos = m.getPosition()
      if (pos) onDragEndRef.current?.({ lng: pos.lng(), lat: pos.lat() })
    })
    setMarker(m)
    return () => {
      m.setMap(null)
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [map])

  useEffect(() => {
    if (!marker) return
    const current = marker.getPosition()
    if (!current || current.lat() !== latitude || current.lng() !== longitude) {
      marker.setPosition({ lat: latitude, lng: longitude })
    }
    if (marker.getDraggable() !== draggable) marker.setDraggable(draggable)
  }, [marker, longitude, latitude, draggable])

  // Status color can change while the marker stays mounted (e.g. a
  // technician flips from on-time to idle) — update the icon in place
  // rather than tearing down and recreating the google.maps.Marker.
  useEffect(() => {
    if (!marker) return
    marker.setIcon(markerIcon(color, variant, rotationDeg))
    marker.setTitle(title ?? null)
  }, [marker, color, variant, rotationDeg, title])

  return null
}

type MapPolylineProps = {
  path: { lat: number; lng: number }[]
  color: string
  weight?: number
  opacity?: number
  zIndex?: number
}

/**
 * A5 — one coloured leg of a technician's route trail. Rendered as one
 * `<MapPolyline>` per classified segment (rather than one long multi-colour
 * polyline) so each segment can carry its own green/yellow/red styling —
 * trail lengths here (a day's worth of ~20s-interval pings) are small enough
 * that per-segment Polyline objects are cheap.
 */
function MapPolyline({ path, color, weight = 4, opacity = 0.9, zIndex }: MapPolylineProps) {
  const { map } = useMap()
  const polylineRef = useRef<google.maps.Polyline | null>(null)
  const pathKey = path.map((p) => `${p.lat.toFixed(6)},${p.lng.toFixed(6)}`).join("|")

  useEffect(() => {
    if (!map) return
    if (path.length < 2) {
      // Premium Live Tracking requirement: log any rendering error to the
      // console — a Polyline with 0-1 points renders nothing, silently, and
      // that's indistinguishable from "the map is just broken" without this.
      console.error("[MapPolyline] Refusing to render — path has fewer than 2 points", { pathLength: path.length })
      return
    }
    const poly = new google.maps.Polyline({
      map,
      path,
      strokeColor: color,
      strokeOpacity: opacity,
      strokeWeight: weight,
      zIndex,
    })
    console.info("[MapPolyline] Rendered polyline on map", { pointCount: path.length, color, weight })
    polylineRef.current = poly
    return () => {
      poly.setMap(null)
    }
    // Recreated whenever the path's actual coordinates change (pathKey), not
    // on every render — color/weight/opacity/zIndex-only changes are handled
    // by the update effect below instead of tearing the polyline down.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [map, pathKey])

  useEffect(() => {
    polylineRef.current?.setOptions({ strokeColor: color, strokeOpacity: opacity, strokeWeight: weight, zIndex })
  }, [color, opacity, weight, zIndex])

  return null
}

/** No-op wrapper kept only so existing `<MapMarker><MarkerContent>...</MarkerContent></MapMarker>` call
 * sites don't need restructuring — see MapMarker's doc comment for why the children aren't rendered. */
function MarkerContent({ children }: { children?: ReactNode }) {
  void children
  return null
}

type MapMarkerLabelProps = {
  longitude: number
  latitude: number
  className?: string
  children: ReactNode
}

/**
 * Persistent text caption anchored to a lat/lng, offset just below that
 * point — unlike MarkerContent (a documented no-op), this actually renders
 * arbitrary React content on the map. A legacy google.maps.Marker can't
 * host DOM/React content directly, so this uses the standard workaround: a
 * custom OverlayView positions a plain div via the map's projection, and
 * React content is portaled into it. `draw()` re-reads position from a ref
 * (not the closure the overlay was constructed with) so calling `.redraw()`
 * on a lat/lng change repositions the *same* div instead of tearing down
 * and recreating the overlay (and thus the portal target) on every GPS
 * update, which would remount — and visibly flicker — the label's children.
 */
function MapMarkerLabel({ longitude, latitude, className, children }: MapMarkerLabelProps) {
  const { map } = useMap()
  const [container, setContainer] = useState<HTMLDivElement | null>(null)
  const overlayRef = useRef<google.maps.OverlayView & { redraw: () => void }>(null)
  const posRef = useRef({ longitude, latitude })
  posRef.current = { longitude, latitude }

  useEffect(() => {
    if (!map) return
    class LabelOverlay extends google.maps.OverlayView {
      div: HTMLDivElement | null = null
      onAdd() {
        const div = document.createElement("div")
        div.style.position = "absolute"
        div.style.transform = "translate(-50%, 6px)"
        div.style.pointerEvents = "none"
        this.div = div
        this.getPanes()!.overlayMouseTarget.appendChild(div)
        setContainer(div)
      }
      draw() {
        if (!this.div) return
        const projection = this.getProjection()
        const { latitude: lat, longitude: lng } = posRef.current
        const point = projection?.fromLatLngToDivPixel(new google.maps.LatLng(lat, lng))
        if (!point) return
        this.div.style.left = `${point.x}px`
        this.div.style.top = `${point.y}px`
      }
      onRemove() {
        this.div?.remove()
        this.div = null
      }
      redraw() {
        this.draw()
      }
    }
    const overlay = new LabelOverlay()
    overlay.setMap(map)
    overlayRef.current = overlay
    return () => {
      overlay.setMap(null)
      overlayRef.current = null
      setContainer(null)
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [map])

  useEffect(() => {
    overlayRef.current?.redraw()
  }, [longitude, latitude])

  if (!container) return null
  return createPortal(<div className={className}>{children}</div>, container)
}

type MapPulseMarkerProps = {
  longitude: number
  latitude: number
  color: string
  size?: number
}

/**
 * "Live" pulse ring centered on a point (Premium Live Tracking's route map —
 * spec: technician marker should feel animated). Same OverlayView+portal
 * technique as MapMarkerLabel above (a legacy google.maps.Marker's Icon is a
 * static raster image with no room for a CSS animation), just centered
 * (`translate(-50%, -50%)`) instead of offset below, and rendering a plain
 * animated ring/dot instead of text. Meant to sit underneath a MapMarker at
 * the same coordinates — mount this first (or give it a lower zIndex
 * expectation) so the marker's own icon renders on top of the ring.
 */
function MapPulseMarker({ longitude, latitude, color, size = 44 }: MapPulseMarkerProps) {
  const { map } = useMap()
  const [container, setContainer] = useState<HTMLDivElement | null>(null)
  const overlayRef = useRef<google.maps.OverlayView & { redraw: () => void }>(null)
  const posRef = useRef({ longitude, latitude })
  posRef.current = { longitude, latitude }

  useEffect(() => {
    if (!map) return
    class PulseOverlay extends google.maps.OverlayView {
      div: HTMLDivElement | null = null
      onAdd() {
        const div = document.createElement("div")
        div.style.position = "absolute"
        div.style.transform = "translate(-50%, -50%)"
        div.style.pointerEvents = "none"
        this.div = div
        this.getPanes()!.overlayLayer.appendChild(div)
        setContainer(div)
      }
      draw() {
        if (!this.div) return
        const projection = this.getProjection()
        const { latitude: lat, longitude: lng } = posRef.current
        const point = projection?.fromLatLngToDivPixel(new google.maps.LatLng(lat, lng))
        if (!point) return
        this.div.style.left = `${point.x}px`
        this.div.style.top = `${point.y}px`
      }
      onRemove() {
        this.div?.remove()
        this.div = null
      }
      redraw() {
        this.draw()
      }
    }
    const overlay = new PulseOverlay()
    overlay.setMap(map)
    overlayRef.current = overlay
    return () => {
      overlay.setMap(null)
      overlayRef.current = null
      setContainer(null)
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [map])

  useEffect(() => {
    overlayRef.current?.redraw()
  }, [longitude, latitude])

  if (!container) return null
  return createPortal(
    <div style={{ width: size, height: size }} className="relative">
      <span className="absolute inset-0 animate-ping rounded-full opacity-40" style={{ backgroundColor: color, animationDuration: "1.8s" }} />
      <span className="absolute inset-[35%] rounded-full" style={{ backgroundColor: color }} />
    </div>,
    container
  )
}

type MapControlsProps = {
  position?: "top-left" | "top-right" | "bottom-left" | "bottom-right"
  showZoom?: boolean
  showLocate?: boolean
  className?: string
  onLocate?: (coords: { longitude: number; latitude: number }) => void
}

const positionClasses = {
  "top-left": "top-2 left-2",
  "top-right": "top-2 right-2",
  "bottom-left": "bottom-2 left-2",
  "bottom-right": "bottom-2 right-2",
}

function ControlGroup({ children }: { children: ReactNode }) {
  return (
    <div className="flex flex-col overflow-hidden rounded-md border border-border bg-surface shadow-sm [&>button:not(:last-child)]:border-b [&>button:not(:last-child)]:border-border">
      {children}
    </div>
  )
}

function ControlButton({
  onClick,
  label,
  children,
  disabled = false,
}: {
  onClick: () => void
  label: string
  children: ReactNode
  disabled?: boolean
}) {
  return (
    <button
      onClick={onClick}
      aria-label={label}
      title={label}
      type="button"
      disabled={disabled}
      className={cn(
        "flex size-8 items-center justify-center text-text-muted transition-colors",
        "hover:bg-surface-alt hover:text-text",
        "disabled:pointer-events-none disabled:opacity-50"
      )}
    >
      {children}
    </button>
  )
}

function MapControls({ position = "bottom-right", showZoom = true, showLocate = false, className, onLocate }: MapControlsProps) {
  const { map } = useMap()
  const [locating, setLocating] = useState(false)

  const handleZoomIn = useCallback(() => {
    if (!map) return
    map.setZoom((map.getZoom() ?? 11) + 1)
  }, [map])

  const handleZoomOut = useCallback(() => {
    if (!map) return
    map.setZoom((map.getZoom() ?? 11) - 1)
  }, [map])

  const handleLocate = useCallback(() => {
    if (!("geolocation" in navigator)) return
    setLocating(true)
    navigator.geolocation.getCurrentPosition(
      (pos) => {
        const coords = { longitude: pos.coords.longitude, latitude: pos.coords.latitude }
        map?.panTo({ lat: coords.latitude, lng: coords.longitude })
        map?.setZoom(15)
        onLocate?.(coords)
        setLocating(false)
      },
      () => setLocating(false)
    )
  }, [map, onLocate])

  return (
    <div className={cn("absolute z-10 flex flex-col gap-1.5", positionClasses[position], className)}>
      {showZoom ? (
        <ControlGroup>
          <ControlButton onClick={handleZoomIn} label="Zoom in">
            <Plus className="size-4" />
          </ControlButton>
          <ControlButton onClick={handleZoomOut} label="Zoom out">
            <Minus className="size-4" />
          </ControlButton>
        </ControlGroup>
      ) : null}
      {showLocate ? (
        <ControlGroup>
          <ControlButton onClick={handleLocate} label="Find my location" disabled={locating}>
            {locating ? <Loader2 className="size-4 animate-spin" /> : <Locate className="size-4" />}
          </ControlButton>
        </ControlGroup>
      ) : null}
    </div>
  )
}

export { Map, useMap, MapMarker, MarkerContent, MapMarkerLabel, MapPulseMarker, MapControls, MapPolyline }
export type { MapViewport }
