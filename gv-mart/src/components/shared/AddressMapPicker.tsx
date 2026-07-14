import { useEffect, useRef, useState } from "react"
import { useTranslation } from "react-i18next"
import { Check, Loader2, MapPin, Search, TriangleAlert } from "lucide-react"
import { Map, MapControls, MapMarker, MarkerContent } from "@/components/ui/map"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { cn } from "@/lib/utils"
import { useDebouncedValue } from "@/hooks/useDebouncedValue"
import { useMapApiKey, useAutocomplete, usePlaceDetails, useGeocodeAddress } from "@/hooks/useMaps"
import type { AutocompletePrediction, GeocodeResult } from "@/services/maps"

// GV Mart operates out of Chennai — a sane default center when no address
// has been picked yet, not a claim about the customer's actual location.
const DEFAULT_CENTER: [number, number] = [80.2707, 13.0827]
const DEFAULT_ZOOM = 11
const PIN_ZOOM = 15

type Coords = { lat: number; lng: number }

function newSessionToken() {
  return crypto.randomUUID()
}

export function AddressMapPicker({
  lat,
  lng,
  onConfirm,
  onAddressSelect,
}: {
  lat?: number
  lng?: number
  /** Fires only when the user explicitly confirms a location (selecting a search result, or confirming a drag adjustment). */
  onConfirm: (coords: Coords) => void
  /** Fires when a search result is picked, before drag adjustment — lets the caller auto-fill area/pincode/district/state. */
  onAddressSelect?: (result: GeocodeResult) => void
}) {
  const { t } = useTranslation()
  const mapApiKey = useMapApiKey()
  const [mapLoadError, setMapLoadError] = useState(false)
  const autocomplete = useAutocomplete()
  const placeDetails = usePlaceDetails()
  const geocodeFallback = useGeocodeAddress()

  const [query, setQuery] = useState("")
  const debouncedQuery = useDebouncedValue(query, 300)
  const [predictions, setPredictions] = useState<AutocompletePrediction[]>([])
  const [fallbackResults, setFallbackResults] = useState<GeocodeResult[]>([])
  const [dropdownOpen, setDropdownOpen] = useState(false)
  const [searchedEmpty, setSearchedEmpty] = useState(false)
  const sessionTokenRef = useRef(newSessionToken())

  const [pin, setPin] = useState<Coords | null>(lat != null && lng != null ? { lat, lng } : null)
  const [draftPin, setDraftPin] = useState<Coords | null>(null)
  const [viewport, setViewport] = useState<{ center: [number, number]; zoom: number }>(() =>
    lat != null && lng != null ? { center: [lng, lat], zoom: PIN_ZOOM } : { center: DEFAULT_CENTER, zoom: DEFAULT_ZOOM }
  )
  const skipNextPropSync = useRef(false)

  // Keep in sync if the parent form resets (e.g. switching customers in edit mode) —
  // but not right after our own onConfirm just wrote these same coords back up.
  useEffect(() => {
    if (skipNextPropSync.current) {
      skipNextPropSync.current = false
      return
    }
    if (lat != null && lng != null) {
      setPin({ lat, lng })
      setViewport({ center: [lng, lat], zoom: PIN_ZOOM })
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [lat, lng])

  // Live-as-you-type suggestions — the whole point of a session token is
  // that every keystroke in one search reuses it, so it's created once above
  // and only rotated once a search actually concludes (see selectPrediction/
  // selectFallbackResult below), not on every render.
  useEffect(() => {
    const q = debouncedQuery.trim()
    if (q.length < 3) {
      setPredictions([])
      setFallbackResults([])
      setSearchedEmpty(false)
      return
    }
    setFallbackResults([])
    setSearchedEmpty(false)
    autocomplete.mutate(
      { input: q, sessionToken: sessionTokenRef.current },
      {
        onSuccess: (found) => {
          setPredictions(found)
          setDropdownOpen(true)
          setSearchedEmpty(found.length === 0)
        },
      }
    )
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [debouncedQuery])

  function applyResult(result: GeocodeResult) {
    const coords = { lat: result.lat, lng: result.lon }
    setPin(coords)
    setDraftPin(null)
    setViewport({ center: [result.lon, result.lat], zoom: PIN_ZOOM })
    setPredictions([])
    setFallbackResults([])
    setDropdownOpen(false)
    setSearchedEmpty(false)
    setQuery(result.formatted)
    sessionTokenRef.current = newSessionToken() // session closed — next search starts fresh
    skipNextPropSync.current = true
    onConfirm(coords)
    onAddressSelect?.(result)
  }

  function selectPrediction(prediction: AutocompletePrediction) {
    placeDetails.mutate(
      { placeId: prediction.placeId, sessionToken: sessionTokenRef.current },
      { onSuccess: applyResult }
    )
  }

  function searchAnyway() {
    geocodeFallback.mutate(query, {
      onSuccess: (results) => {
        setFallbackResults(results)
        setPredictions([])
        setDropdownOpen(true)
      },
    })
  }

  function confirmDraft() {
    if (!draftPin) return
    setPin(draftPin)
    setDraftPin(null)
    skipNextPropSync.current = true
    onConfirm(draftPin)
  }

  function useMyLocation(coords: { longitude: number; latitude: number }) {
    const next = { lat: coords.latitude, lng: coords.longitude }
    setPin(next)
    setDraftPin(null)
    skipNextPropSync.current = true
    onConfirm(next)
  }

  const activePin = draftPin ?? pin
  const suggestionsLoading = autocomplete.isPending
  const resolvingSelection = placeDetails.isPending
  const searchErrored = autocomplete.isError || geocodeFallback.isError
  const dropdownRows = fallbackResults.length > 0 ? fallbackResults : predictions

  return (
    <div className="space-y-2.5">
      <div className="relative">
        <Search className="pointer-events-none absolute left-3 top-1/2 size-4 -translate-y-1/2 text-text-muted" />
        <Input
          value={query}
          onChange={(e) => setQuery(e.target.value)}
          onFocus={() => dropdownRows.length > 0 && setDropdownOpen(true)}
          onBlur={() => setTimeout(() => setDropdownOpen(false), 150)}
          placeholder={t("customers.form.map.searchPlaceholder")}
          className="pl-9 pr-9"
        />
        {suggestionsLoading || resolvingSelection ? (
          <Loader2 className="pointer-events-none absolute right-3 top-1/2 size-4 -translate-y-1/2 animate-spin text-text-muted" />
        ) : null}

        {dropdownOpen && dropdownRows.length > 0 ? (
          <div className="absolute z-20 mt-1 max-h-48 w-full space-y-1 overflow-y-auto rounded-xl border border-border bg-surface p-1.5 shadow-lg">
            {fallbackResults.length > 0
              ? fallbackResults.map((r, i) => (
                  <button
                    key={`${r.lat}-${r.lon}-${i}`}
                    type="button"
                    onMouseDown={(e) => e.preventDefault()}
                    onClick={() => applyResult(r)}
                    className="flex w-full items-start gap-2 rounded-lg px-2.5 py-2 text-left text-sm text-text hover:bg-surface-alt"
                  >
                    <MapPin className="mt-0.5 size-3.5 shrink-0 text-text-muted" />
                    <span className="leading-tight">{r.formatted}</span>
                  </button>
                ))
              : predictions.map((p) => (
                  <button
                    key={p.placeId}
                    type="button"
                    onMouseDown={(e) => e.preventDefault()}
                    onClick={() => selectPrediction(p)}
                    disabled={resolvingSelection}
                    className="flex w-full items-start gap-2 rounded-lg px-2.5 py-2 text-left text-sm text-text hover:bg-surface-alt disabled:opacity-50"
                  >
                    <MapPin className="mt-0.5 size-3.5 shrink-0 text-text-muted" />
                    <span className="leading-tight">{p.description}</span>
                  </button>
                ))}
          </div>
        ) : null}
      </div>

      {searchErrored ? (
        <p className="flex items-center gap-1.5 text-xs text-danger">
          <TriangleAlert className="size-3.5" />
          {t("customers.form.map.searchError")}
        </p>
      ) : null}
      {placeDetails.isError ? (
        <p className="flex items-center gap-1.5 text-xs text-danger">
          <TriangleAlert className="size-3.5" />
          {t("customers.form.map.selectError")}
        </p>
      ) : null}

      {searchedEmpty && !suggestionsLoading && !searchErrored ? (
        <div className="flex items-center justify-between gap-2 text-xs text-text-muted">
          <span>{t("customers.form.map.noResults")}</span>
          <Button
            type="button"
            variant="outline"
            size="sm"
            onMouseDown={(e) => e.preventDefault()}
            onClick={searchAnyway}
            disabled={geocodeFallback.isPending}
          >
            {geocodeFallback.isPending ? <Loader2 className="size-3.5 animate-spin" /> : t("customers.form.map.searchAnywayFor", { query })}
          </Button>
        </div>
      ) : null}

      <div className="relative overflow-hidden rounded-xl border border-border">
        {mapApiKey.isLoading ? (
          <div className="flex h-64 items-center justify-center bg-surface-alt">
            <Loader2 className="size-5 animate-spin text-text-muted" />
          </div>
        ) : mapApiKey.isError || mapLoadError ? (
          <div className="flex h-64 flex-col items-center justify-center gap-1.5 bg-surface-alt px-4 text-center">
            <TriangleAlert className="size-5 text-danger" />
            <p className="text-xs text-text-muted">{t("customers.form.map.mapError")}</p>
          </div>
        ) : (
          <Map
            className="h-64 w-full"
            apiKey={mapApiKey.data}
            viewport={viewport}
            onViewportChange={(v) => setViewport({ center: v.center, zoom: v.zoom })}
            onLoadError={() => setMapLoadError(true)}
          >
            <MapControls showZoom showLocate onLocate={useMyLocation} />
            {activePin ? (
              <MapMarker
                longitude={activePin.lng}
                latitude={activePin.lat}
                draggable
                onDragEnd={(lngLat) => setDraftPin({ lat: lngLat.lat, lng: lngLat.lng })}
              >
                <MarkerContent>
                  <MapPin className="size-7 -translate-y-3.5 fill-accent text-ink drop-shadow" strokeWidth={1.5} />
                </MarkerContent>
              </MapMarker>
            ) : null}
          </Map>
        )}

        {!activePin && !mapApiKey.isLoading && !mapApiKey.isError && !mapLoadError ? (
          <div className="pointer-events-none absolute inset-x-0 bottom-2 flex justify-center">
            <span className="rounded-full bg-ink/80 px-3 py-1 text-xs font-medium text-white">{t("customers.form.map.emptyHint")}</span>
          </div>
        ) : null}
      </div>

      {activePin ? (
        <div className="flex flex-wrap items-center justify-between gap-2 rounded-xl bg-surface-alt px-3 py-2">
          <span className={cn("flex items-center gap-1.5 text-xs font-medium", draftPin ? "text-warning" : "text-success")}>
            {draftPin ? <TriangleAlert className="size-3.5" /> : <Check className="size-3.5" />}
            {draftPin
              ? t("customers.form.map.draftPin")
              : t("customers.form.map.confirmedPin", { lat: pin!.lat.toFixed(6), lng: pin!.lng.toFixed(6) })}
          </span>
          {draftPin ? (
            <Button type="button" size="sm" onClick={confirmDraft}>
              {t("customers.form.map.confirmLocation")}
            </Button>
          ) : null}
        </div>
      ) : null}
    </div>
  )
}
