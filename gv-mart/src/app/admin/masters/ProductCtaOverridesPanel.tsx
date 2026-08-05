import { useTranslation } from "react-i18next"
import { ToggleLeft } from "lucide-react"
import { Dialog, DialogContent, DialogTitle } from "@/components/ui/dialog"
import { useClearProductCtaOverride, useProductCtaOverrides, useSetProductCtaOverride } from "@/hooks/useMasters"
import type { Enums } from "@/types/database"

const CTA_TYPES: Enums<"product_enquiry_cta_type">[] = ["quotation", "callback", "share"]

/**
 * Product Enquiry rebuild (2026-08-04), Phase 1 — per-product CTA override.
 * Org-wide defaults live in product_enquiry_cta_config (Phase 2); this
 * panel only manages the override table — a row here means "this product
 * deviates from the org default," no row means "use the org default,"
 * exactly the complaint_types category-default-or-override hybrid.
 */
export function ProductCtaOverridesPanel({
  orgId,
  productId,
  productName,
  onClose,
}: {
  orgId: string | undefined
  productId: string
  productName: string
  onClose: () => void
}) {
  const { t } = useTranslation()
  const { data: overrides, isLoading } = useProductCtaOverrides(productId)
  const setOverrideMut = useSetProductCtaOverride(productId)
  const clearOverrideMut = useClearProductCtaOverride(productId)

  const overrideFor = (ctaType: Enums<"product_enquiry_cta_type">) => (overrides ?? []).find((o) => o.cta_type === ctaType)

  function handleChange(ctaType: Enums<"product_enquiry_cta_type">, choice: "default" | "on" | "off") {
    if (!orgId) return
    if (choice === "default") {
      clearOverrideMut.mutate(ctaType)
    } else {
      setOverrideMut.mutate({ orgId, ctaType, isEnabled: choice === "on" })
    }
  }

  return (
    <Dialog
      open
      onOpenChange={(next) => {
        if (!next) onClose()
      }}
    >
      <DialogContent>
        <DialogTitle className="flex items-center gap-1.5">
          <ToggleLeft className="size-4 text-accent" />
          {t("masters.productCtaOverrides.title")} — {productName}
        </DialogTitle>

        {isLoading ? (
          <p className="py-4 text-center text-sm text-text-muted">{t("common.loading")}</p>
        ) : (
          <ul className="space-y-2">
            {CTA_TYPES.map((ctaType) => {
              const override = overrideFor(ctaType)
              const current: "default" | "on" | "off" = override == null ? "default" : override.is_enabled ? "on" : "off"
              return (
                <li key={ctaType} className="rounded-xl border border-border p-3">
                  <p className="mb-1.5 text-sm font-medium text-text">{t(`masters.productCtaOverrides.ctaType.${ctaType}`)}</p>
                  <div className="flex gap-1.5">
                    {(["default", "on", "off"] as const).map((choice) => (
                      <button
                        key={choice}
                        type="button"
                        onClick={() => handleChange(ctaType, choice)}
                        className={`rounded-full px-2.5 py-1 text-xs font-semibold ${
                          current === choice ? "bg-accent text-white" : "bg-surface-alt text-text-muted hover:bg-surface-alt/70"
                        }`}
                      >
                        {t(`masters.productCtaOverrides.choice.${choice}`)}
                      </button>
                    ))}
                  </div>
                </li>
              )
            })}
          </ul>
        )}
      </DialogContent>
    </Dialog>
  )
}
