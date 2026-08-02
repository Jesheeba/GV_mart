import type { StatusTone } from "@/components/shared/StatusDot"
import type { Enums } from "@/types/database"

export const BOOKING_STATUS_TONE: Record<Enums<"ticket_status">, StatusTone> = {
  open: "warning",
  assigned: "info",
  in_progress: "warning",
  completed: "success",
  cancelled: "neutral",
}
