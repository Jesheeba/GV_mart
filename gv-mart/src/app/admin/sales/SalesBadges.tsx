import { useTranslation } from "react-i18next"
import { Badge } from "@/components/ui/badge"
import { cn } from "@/lib/utils"
import type { Enums } from "@/types/database"

/**
 * Invoice-type pill colors, matched to the design source
 * (design-template-decoded.html line 1058 iv.tyColor/iv.tyBg): AMC = info
 * blue, Product reuses the same dedicated green TicketBadges.tsx already
 * uses for "warranty" (#16855B/#E2F3EA — distinct from the --success token,
 * kept literal to stay pixel-faithful), Spare is a new literal brown pair
 * from the same source line. The design mocks a 4th type, "Service", but the
 * real invoice_type enum only has product/spare/amc (types/database.ts) so
 * there is no Service badge here.
 */
const INVOICE_TYPE_BADGE_CLASS: Record<Enums<"invoice_type">, string> = {
  product: "text-[#16855B] bg-[#E2F3EA]",
  spare: "text-[#8A6D3B] bg-[#8A6D3B]/[0.14]",
  amc: "text-info bg-info/10",
}

export function InvoiceTypeBadge({ type }: { type: Enums<"invoice_type"> }) {
  const { t } = useTranslation()
  return (
    <Badge variant="outline" className={cn("border-transparent font-bold", INVOICE_TYPE_BADGE_CLASS[type])}>
      {t(`sales.list.filters.${type}`)}
    </Badge>
  )
}

/**
 * Payment-status pill colors, matched to the design source (line 1061
 * iv.stColor/iv.stBg): Paid reuses the same green as the Product type badge,
 * Partial = --warning on its established soft literal bg (already used in
 * TicketsListPage/OwnerDashboard's AttentionRow), Due = --danger likewise.
 */
const PAYMENT_STATUS_BADGE_CLASS: Record<Enums<"payment_status">, string> = {
  paid: "text-[#16855B] bg-[#E2F3EA]",
  partial: "text-warning bg-[#FCF1DF]",
  due: "text-danger bg-[#FCEAEA]",
}

export function PaymentStatusBadge({ status }: { status: Enums<"payment_status"> }) {
  const { t } = useTranslation()
  return (
    <Badge variant="outline" className={cn("border-transparent font-bold", PAYMENT_STATUS_BADGE_CLASS[status])}>
      {t(`sales.invoice.paymentStatus.${status}`)}
    </Badge>
  )
}
