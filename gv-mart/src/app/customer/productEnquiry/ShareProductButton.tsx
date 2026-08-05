import { useTranslation } from "react-i18next"
import { Share2 } from "lucide-react"
import { Button } from "@/components/ui/button"
import { useToast } from "@/components/ui/toast-context"

/**
 * Product Enquiry rebuild (2026-08-04), Phase 4 — "share with family."
 * No public/unauthenticated product URL exists (every /customer/* route is
 * login-walled) and building one is out of scope here, so this shares
 * plain text (name/brand/price/EMI), not a link — navigator.share if
 * available, else clipboard-copy + toast fallback. If a public catalog
 * route is ever built, extend `text` with a real URL — no breaking change
 * to this component's API.
 */
export function ShareProductButton({
  fields,
  name,
  brand,
  price,
  emiPerMonth,
}: {
  fields: string[]
  name: string
  brand: string | null
  price: number
  emiPerMonth: number | null
}) {
  const { t } = useTranslation()
  const { toast } = useToast()

  function buildText() {
    const parts: string[] = []
    if (fields.includes("name")) parts.push(name)
    if (fields.includes("brand") && brand) parts.push(`(${brand})`)
    if (fields.includes("price")) parts.push(`₹${price.toLocaleString("en-IN")}`)
    if (fields.includes("emi") && emiPerMonth != null) parts.push(t("customerApp.productEnquiry.detail.sharePerMonth", { amount: Math.round(emiPerMonth).toLocaleString("en-IN") }))
    return `${parts.join(" — ")}\n${t("customerApp.productEnquiry.detail.shareTagline")}`
  }

  async function handleShare() {
    const text = buildText()
    if (navigator.share) {
      try {
        await navigator.share({ text })
      } catch {
        // user cancelled the native share sheet — not an error
      }
      return
    }
    try {
      await navigator.clipboard.writeText(text)
      toast.success(t("customerApp.productEnquiry.detail.shareCopiedToast"))
    } catch {
      toast.error(t("common.actionFailed"))
    }
  }

  return (
    <Button type="button" variant="outline" size="sm" className="gap-1.5" onClick={handleShare}>
      <Share2 className="size-3.5" />
      {t("customerApp.productEnquiry.detail.shareCta")}
    </Button>
  )
}
