import { useMemo } from "react"
import { useTranslation } from "react-i18next"
import { useNavigate, useParams } from "react-router-dom"
import { ArrowLeft, MapPin } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Card } from "@/components/ui/card"
import { FullPageError, FullPageLoader } from "@/components/shared/FullPageLoader"
import { Map, MapControls, MapMarker, MapPolyline, type MapViewport } from "@/components/ui/map"
import { useProfile } from "@/hooks/useProfile"
import { useMapApiKey } from "@/hooks/useMaps"
import { useJobDetail, useMyTechnician, useTechnicianSettings, useTodaysTechnicianTrail, useTodaysJobs, useTodaysVisitTimings } from "@/hooks/useTechnician"
import { OFFICE_LOCATION, type JobCard } from "@/services/technician"
import { buildDayLegs, classifyRouteTrail, mergeDayLegs, sliceTrailForWindow, ROUTE_COLOR_HEX, type DayJobInput, type ClassifiedRoute } from "@/lib/routeColor"

function toDayJobInput(job: JobCard): DayJobInput {
  return {
    ticketId: job.ticket_id,
    scheduledAt: job.scheduled_at,
    lat: job.service_tickets.addresses?.lat ?? null,
    lng: job.service_tickets.addresses?.lng ?? null,
    customerName: job.service_tickets.customers?.name ?? null,
  }
}

function todayStartIso() {
  const d = new Date()
  d.setHours(0, 0, 0, 0)
  return d.toISOString()
}

/** Centers on the average of every rendered point — no fitBounds helper
 * exists on this app's thin Google Maps wrapper (map.tsx), and a simple
 * average is good enough for a single job's leg(s), which rarely span more
 * than a few km. */
function computeViewport(points: { lat: number; lng: number }[]): MapViewport {
  if (points.length === 0) return { center: [OFFICE_LOCATION.lng, OFFICE_LOCATION.lat], zoom: 12 }
  const avgLat = points.reduce((s, p) => s + p.lat, 0) / points.length
  const avgLng = points.reduce((s, p) => s + p.lng, 0) / points.length
  return { center: [avgLng, avgLat], zoom: 13 }
}

function RouteLegend() {
  const { t } = useTranslation()
  return (
    <div className="flex flex-wrap items-center gap-3 px-1 text-xs text-text-muted">
      <span className="flex items-center gap-1.5">
        <span className="size-2.5 rounded-full" style={{ backgroundColor: ROUTE_COLOR_HEX.green }} /> {t("technician.route.legendGreen")}
      </span>
      <span className="flex items-center gap-1.5">
        <span className="size-2.5 rounded-full" style={{ backgroundColor: ROUTE_COLOR_HEX.yellow }} /> {t("technician.route.legendYellow")}
      </span>
      <span className="flex items-center gap-1.5">
        <span className="size-2.5 rounded-full" style={{ backgroundColor: ROUTE_COLOR_HEX.red }} /> {t("technician.route.legendRed")}
      </span>
    </div>
  )
}

function RouteMapLayer({ route }: { route: ClassifiedRoute }) {
  const { t } = useTranslation()
  return (
    <>
      {route.segments.map((seg, i) => (
        <MapPolyline
          key={i}
          path={[{ lat: seg.from.lat, lng: seg.from.lng }, { lat: seg.to.lat, lng: seg.to.lng }]}
          color={ROUTE_COLOR_HEX[seg.color]}
          weight={5}
        />
      ))}
      {route.idleSpots.map((spot, i) => (
        <MapMarker
          key={i}
          longitude={spot.point.lng}
          latitude={spot.point.lat}
          color={ROUTE_COLOR_HEX.red}
          variant="ring"
          title={t("technician.route.idleForMinutes", { count: Math.round(spot.idleMinutes) })}
        />
      ))}
    </>
  )
}

/**
 * A5(a) — clicking a customer's name in JobDetailPage lands here: this job's
 * specific journey (leg to, and departure from, this customer today),
 * colour-coded green/yellow/red per src/lib/routeColor.ts's
 * classifyRouteTrail, reusing the same technician_locations trail STEP
 * TECH-04's live map already streams — no new tracking, just a coloured
 * replay of it scoped to this one job.
 */
export function JobRoutePage() {
  const { t } = useTranslation()
  const navigate = useNavigate()
  const { ticketId } = useParams<{ ticketId: string }>()

  const { data: profile } = useProfile()
  const technician = useMyTechnician()
  const settings = useTechnicianSettings(profile?.org_id)
  const jobDetail = useJobDetail(ticketId)
  const todaysJobs = useTodaysJobs(technician.data?.id)
  const visitTimings = useTodaysVisitTimings(technician.data?.id)
  const trail = useTodaysTechnicianTrail(technician.data?.id)
  const { data: apiKey } = useMapApiKey()

  const loading = technician.isLoading || jobDetail.isLoading || todaysJobs.isLoading || visitTimings.isLoading || trail.isLoading
  const erroring = technician.isError || jobDetail.isError || todaysJobs.isError || visitTimings.isError || trail.isError

  const { toLeg, fromLeg, toCustomerName, fromCustomerName } = useMemo(() => {
    if (!ticketId || !todaysJobs.data || !visitTimings.data || !trail.data) {
      return { toLeg: null as ClassifiedRoute | null, fromLeg: null as ClassifiedRoute | null, toCustomerName: null as string | null, fromCustomerName: null as string | null }
    }
    const perKmMinutes = settings.data?.per_km_minutes ?? 5
    const legs = mergeDayLegs(todaysJobs.data.map(toDayJobInput), visitTimings.data)
    const windows = buildDayLegs(legs, todayStartIso(), new Date().toISOString())
    const index = windows.findIndex((w) => w.ticketId === ticketId)
    if (index === -1) {
      return { toLeg: null, fromLeg: null, toCustomerName: null, fromCustomerName: null }
    }
    const toWindow = windows[index]
    const fromWindow = windows[index + 1]
    const to = classifyRouteTrail(sliceTrailForWindow(trail.data, toWindow.startIso, toWindow.endIso), {
      perKmMinutes,
      destination: toWindow.destination,
      dueAt: toWindow.dueAt,
    })
    const from = fromWindow
      ? classifyRouteTrail(sliceTrailForWindow(trail.data, fromWindow.startIso, fromWindow.endIso), {
          perKmMinutes,
          destination: fromWindow.destination,
          dueAt: fromWindow.dueAt,
        })
      : null
    // Deliberately a plain lookup object, not `new Map(...)` — this file
    // imports a `Map` component from components/ui/map for the Google Maps
    // wrapper, which shadows the global Map constructor.
    const legByTicket: Record<string, string | null> = {}
    for (const l of legs) legByTicket[l.ticketId] = l.customerName
    return {
      toLeg: to,
      fromLeg: from,
      toCustomerName: legByTicket[toWindow.ticketId ?? ""] ?? null,
      fromCustomerName: fromWindow?.ticketId ? (legByTicket[fromWindow.ticketId] ?? null) : null,
    }
  }, [ticketId, todaysJobs.data, visitTimings.data, trail.data, settings.data])

  if (loading) return <FullPageLoader label={t("common.loading")} />
  if (erroring || !jobDetail.data) {
    return <FullPageError message={t("technician.errors.loadFailed")} onRetry={() => jobDetail.refetch()} retryLabel={t("common.retry")} />
  }

  const ticket = jobDetail.data
  const hasRoute = !!toLeg && (toLeg.segments.length > 0 || !!fromLeg)
  const allPoints = [
    ...(toLeg?.segments.flatMap((s) => [s.from, s.to]) ?? []),
    ...(fromLeg?.segments.flatMap((s) => [s.from, s.to]) ?? []),
  ]
  const viewport = computeViewport(allPoints)

  return (
    <div className="space-y-4 pt-2">
      <div className="flex items-center gap-2">
        <Button type="button" variant="outline" size="xs" onClick={() => navigate(-1)}>
          <ArrowLeft className="size-3.5" />
          {t("common.back")}
        </Button>
        <h1 className="text-xl font-bold text-text">{t("technician.route.title")}</h1>
      </div>

      <Card className="gap-1 py-3">
        <p className="text-sm font-semibold text-text">{ticket.customers?.name ?? t("technician.home.unknownCustomer")}</p>
        <p className="text-xs text-text-muted">{[ticket.addresses?.door_no, ticket.addresses?.area].filter(Boolean).join(", ") || "—"}</p>
      </Card>

      {!hasRoute ? (
        <Card className="items-center gap-2 py-8 text-center">
          <MapPin className="size-8 text-text-muted" />
          <p className="text-sm font-medium text-text">{t("technician.route.noDataTitle")}</p>
          <p className="text-xs text-text-muted">{t("technician.route.noDataBody")}</p>
        </Card>
      ) : (
        <Card size="default" className="gap-0 overflow-hidden py-0">
          <div className="flex items-center justify-between px-4 py-3">
            <p className="text-sm font-semibold text-text">{t("technician.route.mapTitle")}</p>
          </div>
          <div className="border-t border-border px-4 py-2.5">
            <RouteLegend />
          </div>
          <div className="relative h-[420px] w-full border-t border-border">
            {!apiKey ? (
              <div className="flex h-full items-center justify-center text-sm text-text-muted">{t("common.loading")}</div>
            ) : (
              <Map apiKey={apiKey} viewport={viewport} onViewportChange={() => {}}>
                <MapControls position="bottom-right" showZoom />
                {toLeg ? <RouteMapLayer route={toLeg} /> : null}
                {fromLeg ? <RouteMapLayer route={fromLeg} /> : null}
              </Map>
            )}
          </div>
          <div className="space-y-1 px-4 py-3 text-xs text-text-muted">
            {toLeg && toLeg.segments.length > 0 ? <p>{t("technician.route.toLabel", { name: toCustomerName ?? t("technician.home.unknownCustomer") })}</p> : null}
            {fromLeg && fromLeg.segments.length > 0 ? (
              <p>{t("technician.route.fromLabel", { name: fromCustomerName ?? t("technician.route.nextStopUnknown") })}</p>
            ) : null}
          </div>
        </Card>
      )}
    </div>
  )
}
