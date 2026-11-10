import { useTranslation } from "react-i18next"
import { StatusDot, type StatusTone } from "@/components/shared/StatusDot"

/**
 * Part-due indicator for an owned-product card. Deliberately reuses the
 * StatusDot primitive (dot + label) rather than the Badge pill component —
 * that's the exact visual style OwnedProductStatusCard already uses for its
 * own AMC/warranty status rows, and this badge sits inside the same card.
 */
const TONE_BY_STATUS: Record<"due_soon" | "due" | "overdue", StatusTone> = {
  due_soon: "warning",
  due: "warning",
  overdue: "danger",
}

export function PartDueBadge({ status }: { status: "due_soon" | "due" | "overdue" }) {
  const { t } = useTranslation()
  return <StatusDot tone={TONE_BY_STATUS[status]} label={t(`customerLifecycle.badge.${status}`)} />
}
