import { useEffect, useState } from "react"
import { useTranslation } from "react-i18next"
import { CheckCircle2, Coffee, Lock, MapPin, Loader2, TriangleAlert } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Card } from "@/components/ui/card"
import { FullPageError, FullPageLoader } from "@/components/shared/FullPageLoader"
import { PhotoCapture } from "./components/PhotoCapture"
import { useProfile } from "@/hooks/useProfile"
import { useLunchToggle, useMarkAttendance, useMyTechnician, useTechnicianSettings, useTodayAttendance } from "@/hooks/useTechnician"
import { getCurrentPosition, isInsideGeofence, type GeoPoint } from "@/lib/offline/geo"
import { OFFICE_LOCATION } from "@/services/technician"
import { attendanceSchema } from "@/lib/validation/technician"
import { cn } from "@/lib/utils"

type Tick = "affirmation" | "pledge" | "meeting"
const TICK_ORDER: Tick[] = ["affirmation", "pledge", "meeting"]

export function AttendancePage() {
  const { t } = useTranslation()
  const { data: profile } = useProfile()
  const technician = useMyTechnician()
  const settings = useTechnicianSettings(profile?.org_id)
  const attendance = useTodayAttendance(technician.data?.id)
  const markAttendance = useMarkAttendance()
  const lunchToggle = useLunchToggle()

  const [position, setPosition] = useState<GeoPoint | null>(null)
  const [geoError, setGeoError] = useState<string | null>(null)
  const [checkingGeo, setCheckingGeo] = useState(false)
  const [selfie, setSelfie] = useState<string | null>(null)
  const [ticks, setTicks] = useState<Record<Tick, boolean>>({ affirmation: false, pledge: false, meeting: false })
  const [now, setNow] = useState(() => new Date())

  useEffect(() => {
    const interval = setInterval(() => setNow(new Date()), 30_000)
    return () => clearInterval(interval)
  }, [])

  async function refreshLocation() {
    setCheckingGeo(true)
    setGeoError(null)
    try {
      const pos = await getCurrentPosition()
      setPosition(pos)
    } catch {
      setGeoError(t("technician.attendance.locationError"))
    } finally {
      setCheckingGeo(false)
    }
  }

  useEffect(() => {
    void refreshLocation()
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])

  if (technician.isLoading || settings.isLoading || attendance.isLoading) return <FullPageLoader label={t("common.loading")} />
  if (technician.isError || !technician.data) {
    return <FullPageError message={t("technician.errors.loadFailed")} onRetry={() => technician.refetch()} retryLabel={t("common.retry")} />
  }
  if (settings.isError || !settings.data) {
    return <FullPageError message={t("technician.errors.loadFailed")} onRetry={() => settings.refetch()} retryLabel={t("common.retry")} />
  }

  const radiusM = settings.data.geofence_radius_m
  const insideGeofence = position ? isInsideGeofence(position, OFFICE_LOCATION, radiusM) : false
  const alreadyMarked = !!attendance.data
  const lateCutoff = settings.data.late_cutoff // "HH:MM:SS"
  const [cutH, cutM] = lateCutoff.split(":").map(Number)
  const cutoffDate = new Date(now)
  cutoffDate.setHours(cutH, cutM, 0, 0)
  const isPastCutoff = now > cutoffDate
  const locked = alreadyMarked && isPastCutoff

  const nextTickIndex = TICK_ORDER.findIndex((k) => !(attendance.data ? attendance.data[k] : ticks[k]))
  const currentTicks = attendance.data
    ? { affirmation: attendance.data.affirmation, pledge: attendance.data.pledge, meeting: attendance.data.meeting }
    : ticks

  const canMark = !alreadyMarked && insideGeofence && !!selfie && !checkingGeo
  const disabledReason = alreadyMarked
    ? null
    : !insideGeofence
      ? t("technician.attendance.disabledOutsideGeofence")
      : !selfie
        ? t("technician.attendance.disabledNoSelfie")
        : null

  async function handleMark() {
    if (!position || !selfie || !technician.data || !profile) return
    const parsed = attendanceSchema.safeParse({ selfieDataUrl: selfie, affirmation: false, pledge: false, meeting: false })
    if (!parsed.success) return
    const checkInAt = new Date().toISOString()
    await markAttendance.mutateAsync({
      orgId: profile.org_id,
      technicianId: technician.data.id,
      date: new Date().toISOString().slice(0, 10),
      checkInAt,
      insideGeofence: true,
      selfieUrl: selfie,
      isLate: isPastCutoff,
      affirmation: false,
      pledge: false,
      meeting: false,
    })
  }

  const lunchAllowedMin = settings.data?.lunch_minutes_allowed ?? 30
  const lunchRedMin = settings.data?.lunch_minutes_red_threshold ?? 45
  const lunchStart = attendance.data?.lunch_start ?? null
  const lunchEnd = attendance.data?.lunch_end ?? null
  const lunchElapsedMin = lunchStart ? (new Date(lunchEnd ?? now).getTime() - new Date(lunchStart).getTime()) / 60_000 : 0
  const lunchIsRed = lunchElapsedMin > lunchRedMin

  function handleStartLunch() {
    if (!technician.data || !attendance.data) return
    lunchToggle.mutate({ technicianId: technician.data.id, date: attendance.data.date, patch: { lunch_start: new Date().toISOString() } })
  }
  function handleEndLunch() {
    if (!technician.data || !attendance.data) return
    lunchToggle.mutate({ technicianId: technician.data.id, date: attendance.data.date, patch: { lunch_end: new Date().toISOString() } })
  }

  function handleTick(tick: Tick) {
    if (locked) return
    const idx = TICK_ORDER.indexOf(tick)
    if (idx !== nextTickIndex) return // sequential only
    if (!attendance.data) {
      setTicks((prev) => ({ ...prev, [tick]: true }))
      return
    }
    void markAttendance.mutateAsync({
      orgId: profile!.org_id,
      technicianId: technician.data!.id,
      date: attendance.data!.date,
      checkInAt: attendance.data!.check_in_at ?? new Date().toISOString(),
      insideGeofence: attendance.data!.inside_geofence,
      selfieUrl: attendance.data!.selfie_url ?? "",
      isLate: attendance.data!.is_late,
      affirmation: tick === "affirmation" ? true : currentTicks.affirmation,
      pledge: tick === "pledge" ? true : currentTicks.pledge,
      meeting: tick === "meeting" ? true : currentTicks.meeting,
    })
  }

  return (
    <div className="space-y-4 pt-2">
      <h1 className="text-xl font-bold text-text">{t("technician.attendance.title")}</h1>

      {alreadyMarked ? (
        <Card className="items-center gap-2 text-center">
          <CheckCircle2 className="size-8 text-success" />
          <p className="text-sm font-semibold text-text">{t("technician.attendance.markedTitle")}</p>
          <p className="text-xs text-text-muted">
            {t("technician.attendance.markedAt", { time: new Date(attendance.data!.check_in_at ?? "").toLocaleTimeString("en-IN", { hour: "2-digit", minute: "2-digit" }) })}
          </p>
          {attendance.data!.is_late ? (
            <span className="rounded-full bg-danger/10 px-2.5 py-1 text-xs font-medium text-danger">{t("technician.attendance.lateBadge")}</span>
          ) : (
            <span className="rounded-full bg-success/10 px-2.5 py-1 text-xs font-medium text-success">{t("technician.attendance.onTimeBadge")}</span>
          )}
        </Card>
      ) : null}

      {alreadyMarked ? (
        <Card className="gap-2.5">
          <div className="flex items-center gap-2 px-1">
            <Coffee className="size-4 text-text-muted" />
            <p className="text-sm font-semibold text-text">{t("technician.attendance.lunch.title")}</p>
          </div>
          {!lunchStart ? (
            <Button type="button" variant="outline" disabled={lunchToggle.isPending} onClick={handleStartLunch}>
              {lunchToggle.isPending ? <Loader2 className="size-4 animate-spin" /> : t("technician.attendance.lunch.start")}
            </Button>
          ) : (
            <>
              <p className={cn("px-1 text-sm font-medium", lunchIsRed ? "text-danger" : "text-text")}>
                {t(lunchEnd ? "technician.attendance.lunch.durationLabel" : "technician.attendance.lunch.elapsedLabel", { minutes: Math.round(lunchElapsedMin) })}
              </p>
              <p className="px-1 text-xs text-text-muted">{t("technician.attendance.lunch.allowedHint", { allowed: lunchAllowedMin, red: lunchRedMin })}</p>
              {lunchIsRed ? (
                <p className="flex items-center gap-1.5 px-1 text-xs text-danger">
                  <TriangleAlert className="size-3.5" /> {t("technician.attendance.lunch.overLimit")}
                </p>
              ) : null}
              {!lunchEnd ? (
                <Button type="button" disabled={lunchToggle.isPending} onClick={handleEndLunch}>
                  {lunchToggle.isPending ? <Loader2 className="size-4 animate-spin" /> : t("technician.attendance.lunch.end")}
                </Button>
              ) : null}
            </>
          )}
        </Card>
      ) : null}

      {!alreadyMarked ? (
        <Card className="gap-4">
          <div className="flex items-center gap-2 px-1">
            <MapPin className={cn("size-4", insideGeofence ? "text-success" : "text-danger")} />
            <p className="text-sm text-text">
              {checkingGeo
                ? t("technician.attendance.checkingLocation")
                : insideGeofence
                  ? t("technician.attendance.insideOffice")
                  : t("technician.attendance.outsideOffice")}
            </p>
            <Button type="button" size="xs" variant="outline" className="ml-auto" onClick={refreshLocation} disabled={checkingGeo}>
              {checkingGeo ? <Loader2 className="size-3 animate-spin" /> : t("technician.attendance.recheckLocation")}
            </Button>
          </div>
          {geoError ? (
            <p className="flex items-center gap-1.5 px-1 text-xs text-danger">
              <TriangleAlert className="size-3.5" /> {geoError}
            </p>
          ) : null}

          <PhotoCapture label={t("technician.attendance.selfieLabel")} dataUrl={selfie} onCaptured={setSelfie} />

          <Button type="button" disabled={!canMark || markAttendance.isPending} title={disabledReason ?? undefined} onClick={handleMark}>
            {markAttendance.isPending ? <Loader2 className="size-4 animate-spin" /> : t("technician.attendance.markButton")}
          </Button>
          {disabledReason ? <p className="px-1 text-xs text-text-muted">{disabledReason}</p> : null}
        </Card>
      ) : null}

      <Card className="gap-3">
        <div className="flex items-center justify-between px-1">
          <p className="text-sm font-semibold text-text">{t("technician.attendance.checklistTitle")}</p>
          {locked ? (
            <span className="flex items-center gap-1 rounded-full bg-danger/10 px-2.5 py-1 text-xs font-medium text-danger">
              <Lock className="size-3" /> {t("technician.attendance.lockedBanner", { time: lateCutoff.slice(0, 5) })}
            </span>
          ) : null}
        </div>
        {TICK_ORDER.map((tick, idx) => {
          const done = currentTicks[tick]
          const isNext = idx === (alreadyMarked ? TICK_ORDER.findIndex((k) => !currentTicks[k]) : nextTickIndex)
          const enabled = alreadyMarked && !locked && (done || isNext)
          return (
            <button
              key={tick}
              type="button"
              disabled={!enabled || done}
              onClick={() => handleTick(tick)}
              className={cn(
                "flex items-center gap-3 rounded-xl border px-3.5 py-3 text-left transition-colors",
                done ? "border-success/30 bg-success/5" : "border-border",
                !enabled && !done && "opacity-50"
              )}
            >
              <span
                className={cn(
                  "flex size-6 shrink-0 items-center justify-center rounded-full text-xs font-semibold",
                  done ? "bg-success text-white" : "bg-surface-alt text-text-muted"
                )}
              >
                {done ? <CheckCircle2 className="size-4" /> : idx + 1}
              </span>
              <span className="text-sm font-medium text-text">{t(`technician.attendance.tick.${tick}`)}</span>
            </button>
          )
        })}
        {!alreadyMarked ? <p className="px-1 text-xs text-text-muted">{t("technician.attendance.tickHint")}</p> : null}
      </Card>
    </div>
  )
}
