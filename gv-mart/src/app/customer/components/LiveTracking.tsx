import { useEffect, useState } from "react"
import { useTranslation } from "react-i18next"
import { Locate, MapPin, Navigation } from "lucide-react"
import { supabase } from "@/lib/supabase"
import { useLatestTechnicianLocation } from "@/hooks/useCustomerApp"
import { useMapApiKey } from "@/hooks/useMaps"
import { Map, MapMarker, MapMarkerLabel, type MapViewport } from "@/components/ui/map"
import { Button } from "@/components/ui/button"
import type { TechnicianLocationRow } from "@/services/customerApp"

const LABEL_CLASS =
  "whitespace-nowrap rounded-md border border-border bg-surface px-1.5 py-0.5 text-[10px] font-medium text-text shadow-sm"

/**
 * CUST-07 live technician ETA tracking. Reuses Supabase Realtime on
 * `technician_locations` — RLS only lets a customer read location rows for
 * a technician with an active (scheduled/in_progress) appointment on one of
 * their OWN tickets (see migration 20260702130000_customer_app_rls.sql), so
 * this component is safe to mount for any technicianId the caller passes in
 * as long as it came from that customer's own ticket/appointment data.
 *
 * Renders the technician's live position on the same Google Map used by
 * TechniciansMapPage/MapPage (see src/components/ui/map.tsx +
 * useMapApiKey) — no separate key/setup needed, it's the same already-
 * configured Maps Platform project.
 */
export function LiveTracking({ technicianId, technicianName }: { technicianId: string; technicianName?: string }) {
  const { t } = useTranslation()
  const { data: initialLocation, isLoading } = useLatestTechnicianLocation(technicianId)
  const [location, setLocation] = useState<TechnicianLocationRow | null>(null)
  const { data: apiKey, isError: apiKeyError } = useMapApiKey()
  const [viewport, setViewport] = useState<MapViewport | null>(null)
  const [mapLoadFailed, setMapLoadFailed] = useState(false)
  const [isFollowing, setIsFollowing] = useState(true)

  useEffect(() => {
    setLocation(initialLocation ?? null)
  }, [initialLocation])

  useEffect(() => {
    const channel = supabase
      .channel(`technician-location-${technicianId}`)
      .on(
        "postgres_changes",
        { event: "INSERT", schema: "public", table: "technician_locations", filter: `technician_id=eq.${technicianId}` },
        (payload) => setLocation(payload.new as TechnicianLocationRow)
      )
      .subscribe()

    return () => {
      supabase.removeChannel(channel)
    }
  }, [technicianId])

  // Centers on the technician's first known position, then keeps following
  // fresh Realtime pings only while the customer hasn't manually panned —
  // once they pan (isFollowing goes false via handleViewportChange below),
  // new pings no longer yank the map back until they tap "Recenter".
  useEffect(() => {
    if (!location) return
    setViewport((prev) => (prev && !isFollowing ? prev : { center: [location.lng, location.lat], zoom: prev?.zoom ?? 15 }))
  }, [location, isFollowing])

  const handleViewportChange = (next: MapViewport) => {
    setViewport(next)
    setIsFollowing(false)
  }

  const handleRecenter = () => {
    setIsFollowing(true)
  }

  if (isLoading) {
    return <div className="animate-pulse rounded-xl bg-surface-alt px-3.5 py-6 text-center text-sm text-text-muted">{t("common.loading")}</div>
  }

  if (!location) {
    return (
      <div className="flex flex-col items-center gap-1.5 rounded-xl border border-dashed border-border px-3.5 py-6 text-center">
        <MapPin className="size-5 text-text-muted" />
        <p className="text-sm text-text-muted">{t("customerApp.tracking.noLocationYet")}</p>
      </div>
    )
  }

  const updatedAt = new Date(location.recorded_at)
  const minutesAgo = Math.max(0, Math.round((Date.now() - updatedAt.getTime()) / 60_000))

  return (
    <div className="space-y-2 rounded-xl border border-border bg-surface-alt/40 px-3.5 py-3">
      <div className="flex items-center gap-2">
        <span className="flex size-8 shrink-0 items-center justify-center rounded-full bg-success/15 text-success">
          <Navigation className="size-4" />
        </span>
        <div>
          <p className="text-sm font-semibold text-text">
            {technicianName ? t("customerApp.tracking.onTheWayNamed", { name: technicianName }) : t("customerApp.tracking.onTheWay")}
          </p>
          <p className="text-xs text-text-muted">
            {minutesAgo <= 0 ? t("customerApp.tracking.updatedJustNow") : t("customerApp.tracking.updatedMinutesAgo", { count: minutesAgo })}
          </p>
        </div>
      </div>
      <div className="relative h-48 w-full overflow-hidden rounded-lg border border-border">
        {!apiKey ? (
          <div className="flex h-full items-center justify-center">
            {apiKeyError ? (
              <p className="px-3 text-center text-xs text-text-muted">{t("customerApp.tracking.mapLoadFailed")}</p>
            ) : (
              <p className="text-xs text-text-muted">{t("common.loading")}</p>
            )}
          </div>
        ) : mapLoadFailed ? (
          <div className="flex h-full items-center justify-center">
            <p className="px-3 text-center text-xs text-text-muted">{t("customerApp.tracking.mapLoadFailed")}</p>
          </div>
        ) : viewport ? (
          <Map apiKey={apiKey} viewport={viewport} onViewportChange={handleViewportChange} onLoadError={() => setMapLoadFailed(true)}>
            <MapMarker longitude={location.lng} latitude={location.lat} title={technicianName} />
            {technicianName ? (
              <MapMarkerLabel longitude={location.lng} latitude={location.lat} className={LABEL_CLASS}>
                {technicianName}
              </MapMarkerLabel>
            ) : null}
            {!isFollowing ? (
              <Button
                type="button"
                variant="outline"
                size="icon-sm"
                onClick={handleRecenter}
                aria-label={t("customerApp.tracking.recenter")}
                title={t("customerApp.tracking.recenter")}
                className="absolute right-2 bottom-2 z-10 bg-surface shadow-sm"
              >
                <Locate className="size-4" />
              </Button>
            ) : null}
          </Map>
        ) : null}
      </div>
    </div>
  )
}
