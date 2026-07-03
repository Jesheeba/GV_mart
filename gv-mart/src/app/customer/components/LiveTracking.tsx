import { useEffect, useState } from "react"
import { useTranslation } from "react-i18next"
import { MapPin, Navigation } from "lucide-react"
import { supabase } from "@/lib/supabase"
import { useLatestTechnicianLocation } from "@/hooks/useCustomerApp"
import type { TechnicianLocationRow } from "@/services/customerApp"

/**
 * CUST-07 live technician ETA tracking. Reuses Supabase Realtime on
 * `technician_locations` — RLS only lets a customer read location rows for
 * a technician with an active (scheduled/in_progress) appointment on one of
 * their OWN tickets (see migration 20260702130000_customer_app_rls.sql), so
 * this component is safe to mount for any technicianId the caller passes in
 * as long as it came from that customer's own ticket/appointment data.
 *
 * No map SDK key is configured in this environment, so this renders a
 * lightweight coordinate + "last updated" readout instead of an embedded
 * map tile — swapping in Google Maps/Leaflet later only touches this file.
 */
export function LiveTracking({ technicianId, technicianName }: { technicianId: string; technicianName?: string }) {
  const { t } = useTranslation()
  const { data: initialLocation, isLoading } = useLatestTechnicianLocation(technicianId)
  const [location, setLocation] = useState<TechnicianLocationRow | null>(null)

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
      <div className="flex items-center gap-1.5 text-xs text-text-muted">
        <MapPin className="size-3.5" />
        <span className="tabular-nums">
          {location.lat.toFixed(5)}, {location.lng.toFixed(5)}
        </span>
      </div>
    </div>
  )
}
