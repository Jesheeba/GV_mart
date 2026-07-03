import { useEffect, useState } from "react"
import { useTranslation } from "react-i18next"
import { useNavigate, useSearchParams } from "react-router-dom"
import { CheckCircle2, Loader2, MapPin, Navigation, TriangleAlert } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Card } from "@/components/ui/card"
import { FullPageError, FullPageLoader } from "@/components/shared/FullPageLoader"
import { useProfile } from "@/hooks/useProfile"
import { useJobDetail, useMyTechnician, useQueueLocationPing, useTechnicianSettings, useTodaysJobs } from "@/hooks/useTechnician"
import { distanceKm, expectedMinutes, getCurrentPosition, type GeoPoint } from "@/lib/offline/geo"
import { OFFICE_LOCATION } from "@/services/technician"
import { cn } from "@/lib/utils"

function googleMapsUrl(dest: GeoPoint) {
  return `https://www.google.com/maps/dir/?api=1&destination=${dest.lat},${dest.lng}`
}

export function MapPage() {
  const { t } = useTranslation()
  const navigate = useNavigate()
  const [searchParams] = useSearchParams()
  const ticketId = searchParams.get("ticketId") ?? undefined

  const { data: profile } = useProfile()
  const technician = useMyTechnician()
  const settings = useTechnicianSettings(profile?.org_id)
  const jobDetail = useJobDetail(ticketId)
  const todaysJobs = useTodaysJobs(technician.data?.id)
  const queueLocationPing = useQueueLocationPing()

  const [position, setPosition] = useState<GeoPoint | null>(null)
  const [geoError, setGeoError] = useState<string | null>(null)
  const [checkingGeo, setCheckingGeo] = useState(false)
  const [arrived, setArrived] = useState(false)
  const [arrivedAt, setArrivedAt] = useState<number | null>(null)
  const [elapsedSec, setElapsedSec] = useState(0)

  async function refreshLocation() {
    setCheckingGeo(true)
    setGeoError(null)
    try {
      const pos = await getCurrentPosition()
      setPosition(pos)
    } catch {
      setGeoError(t("technician.map.locationError"))
    } finally {
      setCheckingGeo(false)
    }
  }

  useEffect(() => {
    void refreshLocation()
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])

  useEffect(() => {
    if (!arrivedAt) return
    const interval = setInterval(() => setElapsedSec(Math.floor((Date.now() - arrivedAt) / 1000)), 1000)
    return () => clearInterval(interval)
  }, [arrivedAt])

  if (technician.isLoading || settings.isLoading) return <FullPageLoader label={t("common.loading")} />
  if (technician.isError || !technician.data) {
    return <FullPageError message={t("technician.errors.loadFailed")} onRetry={() => technician.refetch()} retryLabel={t("common.retry")} />
  }

  // Destination: the requested ticket's address if given, else the nearest scheduled job today.
  const ticket = jobDetail.data
  const fallbackJob = !ticketId ? todaysJobs.data?.[0] : undefined
  const destAddress = ticket?.addresses ?? fallbackJob?.service_tickets.addresses ?? null
  const destCustomerName = ticket?.customers?.name ?? fallbackJob?.service_tickets.customers?.name ?? null
  const destTicketId = ticketId ?? fallbackJob?.ticket_id ?? null
  const dest: GeoPoint | null = destAddress?.lat != null && destAddress?.lng != null ? { lat: destAddress.lat, lng: destAddress.lng } : null

  const origin = position ?? OFFICE_LOCATION
  const perKmMinutes = settings.data?.per_km_minutes ?? 5
  const km = dest ? distanceKm(origin, dest) : null
  const etaMinutes = km != null ? Math.round(expectedMinutes(km, perKmMinutes)) : null

  // Distance-reach indicator (BuildSpec: "green on-time / red off-route or
  // idle"): green once close to the destination or already arrived; red when
  // location tracking has failed (idle, no fix) — otherwise amber while en route.
  const isClose = km != null && km <= 0.3
  const isIdle = !!geoError && !position
  const indicatorState: "on-time" | "tracking" | "idle" = isClose || arrived ? "on-time" : isIdle ? "idle" : "tracking"
  const statusColor = indicatorState === "on-time" ? "text-success" : indicatorState === "idle" ? "text-danger" : "text-warning"
  const statusDotColor = indicatorState === "on-time" ? "bg-success" : indicatorState === "idle" ? "bg-danger" : "bg-warning"
  const statusLabel =
    indicatorState === "on-time"
      ? t("technician.map.statusOnRoute")
      : indicatorState === "idle"
        ? t("technician.map.statusIdle")
        : t("technician.map.statusTracking")

  async function handleArrived() {
    if (!position || !profile || !technician.data) return
    await queueLocationPing.mutateAsync({ orgId: profile.org_id, technicianId: technician.data.id, lat: position.lat, lng: position.lng })
    setArrived(true)
    setArrivedAt(Date.now())
  }

  const minutes = String(Math.floor(elapsedSec / 60)).padStart(2, "0")
  const seconds = String(elapsedSec % 60).padStart(2, "0")

  return (
    <div className="space-y-4 pt-2">
      <h1 className="text-xl font-bold text-text">{t("technician.map.title")}</h1>

      {!dest ? (
        <Card className="items-center gap-2 py-8 text-center">
          <MapPin className="size-8 text-text-muted" />
          <p className="text-sm font-medium text-text">{t("technician.map.noDestinationTitle")}</p>
          <p className="text-xs text-text-muted">{t("technician.map.noDestinationBody")}</p>
        </Card>
      ) : (
        <>
          <Card className="gap-3">
            <div className="flex items-center gap-2 px-1">
              <span className={cn("flex size-2.5 shrink-0 rounded-full", statusDotColor)} />
              <p className={cn("text-sm font-medium", statusColor)}>{statusLabel}</p>
              <Button type="button" size="xs" variant="outline" className="ml-auto" onClick={refreshLocation} disabled={checkingGeo}>
                {checkingGeo ? <Loader2 className="size-3 animate-spin" /> : t("technician.map.refreshLocation")}
              </Button>
            </div>
            {geoError ? (
              <p className="flex items-center gap-1.5 px-1 text-xs text-danger">
                <TriangleAlert className="size-3.5" /> {geoError}
              </p>
            ) : null}

            <div className="grid grid-cols-2 gap-3 px-1">
              <div>
                <p className="text-xs text-text-muted">{t("technician.map.distance")}</p>
                <p className="text-lg font-semibold text-text">{km != null ? t("technician.map.distanceKm", { km: km.toFixed(1) }) : "—"}</p>
              </div>
              <div>
                <p className="text-xs text-text-muted">{t("technician.map.eta")}</p>
                <p className="text-lg font-semibold text-text">{etaMinutes != null ? t("technician.map.etaMinutes", { minutes: etaMinutes }) : "—"}</p>
              </div>
            </div>

            <div className="px-1">
              <p className="text-sm font-medium text-text">{destCustomerName ?? t("technician.home.unknownCustomer")}</p>
              <p className="text-xs text-text-muted">{[destAddress?.door_no, destAddress?.area].filter(Boolean).join(", ") || "—"}</p>
            </div>

            <a href={googleMapsUrl(dest)} target="_blank" rel="noreferrer" className="w-full">
              <Button type="button" variant="outline" className="w-full">
                <Navigation className="size-4" />
                {t("technician.map.openInMaps")}
              </Button>
            </a>
          </Card>

          <Card className="gap-3">
            {arrived ? (
              <div className="items-center gap-2 text-center">
                <CheckCircle2 className="mx-auto size-8 text-success" />
                <p className="text-sm font-semibold text-text">{t("technician.map.arrivedTitle")}</p>
                <p className="font-mono text-2xl font-bold text-text">
                  {minutes}:{seconds}
                </p>
                <p className="text-xs text-text-muted">{t("technician.map.productivityTimerNote")}</p>
                {destTicketId ? (
                  <Button type="button" className="mt-2 w-full" onClick={() => navigate(`/technician/jobs/${destTicketId}/visit`)}>
                    {t("technician.map.startService")}
                  </Button>
                ) : null}
              </div>
            ) : (
              <Button type="button" disabled={!position || queueLocationPing.isPending} onClick={handleArrived}>
                {queueLocationPing.isPending ? <Loader2 className="size-4 animate-spin" /> : t("technician.map.arrivedButton")}
              </Button>
            )}
          </Card>
        </>
      )}
    </div>
  )
}
