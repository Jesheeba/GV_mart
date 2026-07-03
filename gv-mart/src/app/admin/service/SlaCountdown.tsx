import { useEffect, useState } from "react"
import { useTranslation } from "react-i18next"
import { StatusDot, type StatusTone } from "@/components/shared/StatusDot"

/**
 * Live SLA countdown from `sla_due_at` (ADM-09). Color status:
 * green = plenty of time left, amber = due within 2 hours (or already
 * completed/cancelled shows neutral), red = overdue. Ticks every 30s — a
 * ticket list doesn't need per-second precision, just to visibly count down.
 */
export function SlaCountdown({ slaDueAt, status }: { slaDueAt: string | null; status: string }) {
  const { t } = useTranslation()
  const [now, setNow] = useState(() => Date.now())

  useEffect(() => {
    if (!slaDueAt || status === "completed" || status === "cancelled") return
    const id = setInterval(() => setNow(Date.now()), 30_000)
    return () => clearInterval(id)
  }, [slaDueAt, status])

  if (!slaDueAt) {
    return <StatusDot tone="neutral" label={t("service.sla.none")} />
  }
  if (status === "completed") {
    return <StatusDot tone="success" label={t("service.sla.completed")} />
  }
  if (status === "cancelled") {
    return <StatusDot tone="neutral" label={t("service.sla.cancelled")} />
  }

  const diffMs = new Date(slaDueAt).getTime() - now
  const overdue = diffMs <= 0
  const dueSoon = !overdue && diffMs <= 2 * 60 * 60 * 1000
  const tone: StatusTone = overdue ? "danger" : dueSoon ? "warning" : "success"

  const absMs = Math.abs(diffMs)
  const hours = Math.floor(absMs / 3_600_000)
  const minutes = Math.floor((absMs % 3_600_000) / 60_000)
  const label = overdue
    ? t("service.sla.overdueBy", { hours, minutes })
    : t("service.sla.dueIn", { hours, minutes })

  return <StatusDot tone={tone} label={label} />
}
