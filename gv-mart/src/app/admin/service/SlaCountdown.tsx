import { useEffect, useRef, useState } from "react"
import { useTranslation } from "react-i18next"
import { StatusDot, type StatusTone } from "@/components/shared/StatusDot"

/**
 * Live SLA countdown from `sla_due_at` (ADM-09). Color status:
 * green = plenty of time left, amber = due within 2 hours (or already
 * completed/cancelled shows neutral), red = overdue. Ticks every 30s — a
 * ticket list doesn't need per-second precision, just to visibly count down.
 *
 * A visually-hidden `aria-live` region announces only when the tone flips
 * into warning/danger (i.e. the ticket crosses into "due soon" or
 * "overdue") — not on every 30s tick, which would spam assistive tech.
 */
export function SlaCountdown({ slaDueAt, status }: { slaDueAt: string | null; status: string }) {
  const { t } = useTranslation()
  const [now, setNow] = useState(() => Date.now())
  const [announcement, setAnnouncement] = useState("")
  const prevToneRef = useRef<StatusTone | null>(null)

  useEffect(() => {
    if (!slaDueAt || status === "completed" || status === "cancelled") return
    const id = setInterval(() => setNow(Date.now()), 30_000)
    return () => clearInterval(id)
  }, [slaDueAt, status])

  const active = Boolean(slaDueAt) && status !== "completed" && status !== "cancelled"
  const diffMs = active ? new Date(slaDueAt as string).getTime() - now : 0
  const overdue = active && diffMs <= 0
  const dueSoon = active && !overdue && diffMs <= 2 * 60 * 60 * 1000
  const tone: StatusTone = !slaDueAt
    ? "neutral"
    : status === "completed"
      ? "success"
      : status === "cancelled"
        ? "neutral"
        : overdue
          ? "danger"
          : dueSoon
            ? "warning"
            : "success"

  useEffect(() => {
    if (active && prevToneRef.current !== null && prevToneRef.current !== tone) {
      if (tone === "warning") setAnnouncement(t("service.sla.announceDueSoon"))
      else if (tone === "danger") setAnnouncement(t("service.sla.announceOverdue"))
    }
    prevToneRef.current = tone
  }, [active, tone, t])

  const liveRegion = (
    <span className="sr-only" role="status" aria-live="polite">
      {announcement}
    </span>
  )

  if (!slaDueAt) {
    return <StatusDot tone="neutral" label={t("service.sla.none")} />
  }
  if (status === "completed") {
    return <StatusDot tone="success" label={t("service.sla.completed")} />
  }
  if (status === "cancelled") {
    return <StatusDot tone="neutral" label={t("service.sla.cancelled")} />
  }

  const absMs = Math.abs(diffMs)
  const hours = Math.floor(absMs / 3_600_000)
  const minutes = Math.floor((absMs % 3_600_000) / 60_000)
  const label = overdue
    ? t("service.sla.overdueBy", { hours, minutes })
    : t("service.sla.dueIn", { hours, minutes })

  return (
    <>
      <StatusDot tone={tone} label={label} />
      {liveRegion}
    </>
  )
}
