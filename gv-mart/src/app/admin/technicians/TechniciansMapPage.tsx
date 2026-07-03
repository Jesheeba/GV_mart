import { useEffect, useState } from "react"
import { useTranslation } from "react-i18next"
import { MapPin, Navigation } from "lucide-react"
import { Card } from "@/components/ui/card"
import { StatusDot } from "@/components/shared/StatusDot"
import { useProfile } from "@/hooks/useProfile"
import { useTechniciansWithLocation } from "@/hooks/useTechniciansAdmin"
import { supabase } from "@/lib/supabase"
import type { TechnicianLocationRow, TechnicianWithLatestLocation } from "@/services/techniciansAdmin"
import { cn } from "@/lib/utils"

const IDLE_THRESHOLD_MINUTES = 8

/**
 * ADM-15. No Google Maps API key is configured in this environment (same
 * constraint noted in src/app/technician/MapPage.tsx and
 * src/app/customer/components/LiveTracking.tsx) — this mirrors their
 * non-SDK visual approach: a side list + a lightweight coordinate grid
 * "pin board" instead of an embedded map tile. Swapping in a real map SDK
 * later only touches this file.
 *
 * Green = location updated within IDLE_THRESHOLD_MINUTES (on-route/on-time
 * proxy). Red = no update for longer than that, or no location at all
 * (idle/off-route proxy) — a stub-quality heuristic per the build brief,
 * not real routing.
 */
export function TechniciansMapPage() {
  const { t } = useTranslation()
  const { data: profile } = useProfile()
  const orgId = profile?.org_id

  const { data: technicians, isLoading, isError, refetch } = useTechniciansWithLocation(orgId)
  const [liveLocations, setLiveLocations] = useState<Record<string, TechnicianLocationRow>>({})
  const [selectedId, setSelectedId] = useState<string | null>(null)
  const [now, setNow] = useState(() => Date.now())

  useEffect(() => {
    const interval = setInterval(() => setNow(Date.now()), 15_000)
    return () => clearInterval(interval)
  }, [])

  useEffect(() => {
    if (!orgId) return
    const channel = supabase
      .channel(`admin-technician-locations-${orgId}`)
      .on(
        "postgres_changes",
        { event: "INSERT", schema: "public", table: "technician_locations", filter: `org_id=eq.${orgId}` },
        (payload) => {
          const row = payload.new as TechnicianLocationRow
          setLiveLocations((prev) => ({ ...prev, [row.technician_id]: row }))
        }
      )
      .subscribe()
    return () => {
      supabase.removeChannel(channel)
    }
  }, [orgId])

  const rows: TechnicianWithLatestLocation[] = (technicians ?? []).map((r) => ({
    ...r,
    latestLocation: liveLocations[r.id] ?? r.latestLocation,
  }))

  function isOnTime(row: TechnicianWithLatestLocation) {
    if (!row.latestLocation) return false
    const minutesAgo = (now - new Date(row.latestLocation.recorded_at).getTime()) / 60_000
    return minutesAgo <= IDLE_THRESHOLD_MINUTES
  }

  const selected = rows.find((r) => r.id === selectedId) ?? null

  return (
    <div className="space-y-4 pt-2">
      <div>
        <h1 className="text-2xl font-bold text-text">{t("technicians.map.title")}</h1>
        <p className="text-sm text-text-muted">{t("technicians.map.subtitle")}</p>
      </div>

      <div className="grid grid-cols-1 gap-4 lg:grid-cols-[320px_1fr]">
        <Card size="default" className="max-h-[600px] gap-2 overflow-y-auto">
          <p className="px-1 text-sm font-semibold text-text">{t("technicians.map.sideListTitle")}</p>
          {isLoading ? (
            <p className="px-1 text-sm text-text-muted">{t("common.loading")}</p>
          ) : isError ? (
            <div className="px-1 text-sm text-danger">
              {t("technicians.map.loadFailed")}{" "}
              <button className="underline" onClick={() => refetch()}>
                {t("common.retry")}
              </button>
            </div>
          ) : rows.length === 0 ? (
            <p className="px-1 text-sm text-text-muted">{t("technicians.map.empty")}</p>
          ) : (
            <div className="divide-y divide-border">
              {rows.map((row) => {
                const onTime = isOnTime(row)
                const minutesAgo = row.latestLocation
                  ? Math.round((now - new Date(row.latestLocation.recorded_at).getTime()) / 60_000)
                  : null
                return (
                  <button
                    key={row.id}
                    type="button"
                    onClick={() => setSelectedId(row.id)}
                    className={cn(
                      "flex w-full items-center justify-between gap-2 px-1 py-2.5 text-left transition-colors hover:bg-surface-alt",
                      selectedId === row.id && "bg-surface-alt"
                    )}
                  >
                    <div>
                      <p className="text-sm font-medium text-text">{row.profiles?.full_name ?? "—"}</p>
                      <p className="text-xs text-text-muted">
                        {minutesAgo != null
                          ? t("technicians.map.updatedMinutesAgo", { count: minutesAgo })
                          : t("technicians.map.noLocationYet")}
                      </p>
                    </div>
                    <StatusDot
                      tone={onTime ? "success" : "danger"}
                      label={onTime ? t("technicians.map.statusOnRoute") : t("technicians.map.statusIdle")}
                    />
                  </button>
                )
              })}
            </div>
          )}
        </Card>

        <Card size="default" className="min-h-[420px] gap-3">
          <p className="px-1 text-sm font-semibold text-text">{t("technicians.map.pinBoardTitle")}</p>
          {rows.filter((r) => r.latestLocation).length === 0 ? (
            <div className="flex flex-1 flex-col items-center justify-center gap-2 py-16 text-center">
              <MapPin className="size-8 text-text-muted" />
              <p className="text-sm font-medium text-text">{t("technicians.map.noPinsTitle")}</p>
              <p className="text-xs text-text-muted">{t("technicians.map.noPinsBody")}</p>
            </div>
          ) : (
            <div className="grid grid-cols-2 gap-3 p-2 sm:grid-cols-3">
              {rows
                .filter((r) => r.latestLocation)
                .map((row) => {
                  const onTime = isOnTime(row)
                  return (
                    <button
                      key={row.id}
                      type="button"
                      onClick={() => setSelectedId(row.id)}
                      className={cn(
                        "flex flex-col items-center gap-1.5 rounded-xl border p-3 text-center transition-colors",
                        onTime ? "border-success/30 bg-success/5" : "border-danger/30 bg-danger/5",
                        selectedId === row.id && "ring-2 ring-ring"
                      )}
                    >
                      <span
                        className={cn(
                          "flex size-9 items-center justify-center rounded-full text-white",
                          onTime ? "bg-success" : "bg-danger"
                        )}
                      >
                        <Navigation className="size-4" />
                      </span>
                      <p className="text-xs font-semibold text-text">{row.profiles?.full_name ?? "—"}</p>
                      <p className="font-mono text-[10px] text-text-muted">
                        {row.latestLocation!.lat.toFixed(4)}, {row.latestLocation!.lng.toFixed(4)}
                      </p>
                    </button>
                  )
                })}
            </div>
          )}

          {selected ? (
            <div className="mt-2 rounded-xl border border-border bg-surface-alt/40 px-3.5 py-3">
              <p className="text-sm font-semibold text-text">{selected.profiles?.full_name ?? "—"}</p>
              <p className="text-xs text-text-muted">{selected.profiles?.phone ?? "—"}</p>
              {selected.latestLocation ? (
                <p className="mt-1 font-mono text-xs text-text-muted">
                  {selected.latestLocation.lat.toFixed(5)}, {selected.latestLocation.lng.toFixed(5)} ·{" "}
                  {new Date(selected.latestLocation.recorded_at).toLocaleTimeString("en-IN")}
                </p>
              ) : (
                <p className="mt-1 text-xs text-text-muted">{t("technicians.map.noLocationYet")}</p>
              )}
            </div>
          ) : null}
        </Card>
      </div>
    </div>
  )
}
