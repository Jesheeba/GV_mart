import type { StatusTone } from "@/components/shared/StatusDot"
import type { AmcStatus } from "@/services/amc"

export const AMC_STATUS_TONE: Record<AmcStatus, StatusTone> = {
  active: "success",
  due_soon: "warning",
  expired: "danger",
}
