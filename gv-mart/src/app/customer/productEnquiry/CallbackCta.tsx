import { useNavigate } from "react-router-dom"
import { Button } from "@/components/ui/button"

/**
 * Product Enquiry rebuild (2026-08-04), Phase 4 — "Request a Callback" CTA.
 * Just navigates to the dedicated callback route (date + slot picking is
 * its own screen, not an inline dialog — reuses appointment_slots, a real
 * admin-configured list worth its own page).
 */
export function CallbackCta({ productId, label }: { productId: string; label: string }) {
  const navigate = useNavigate()
  return (
    <Button type="button" variant="outline" className="w-full" onClick={() => navigate(`/customer/product-enquiry/callback?productId=${productId}`)}>
      {label}
    </Button>
  )
}
