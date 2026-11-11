import { useState } from "react"
import { useTranslation } from "react-i18next"
import { Dialog, DialogContent, DialogTitle } from "@/components/ui/dialog"
import { cn } from "@/lib/utils"
import { BrandsTab } from "./BrandsTab"
import { ModelsTab } from "./ModelsTab"

// Renaming, recategorizing or deleting a Brand/Model is rare next to adding
// one (which now happens inline on the Product form itself, see
// ProductsTab's "creatable" brand_id/model_id fields) — this panel is just
// where that rare edit still happens, opened from a single button instead of
// two standalone Masters tabs.
export function ManageBrandsModelsPanel({ onClose }: { onClose: () => void }) {
  const { t } = useTranslation()
  const [sub, setSub] = useState<"brands" | "models">("brands")

  return (
    <Dialog open onOpenChange={(open) => !open && onClose()}>
      <DialogContent className="max-w-2xl">
        <DialogTitle>{t("masters.manageBrandsModels.title")}</DialogTitle>
        <div className="flex gap-1 rounded-xl bg-surface-alt p-1">
          {(["brands", "models"] as const).map((s) => (
            <button
              key={s}
              type="button"
              onClick={() => setSub(s)}
              className={cn(
                "flex-1 rounded-lg px-3 py-1.5 text-sm font-medium transition-colors",
                sub === s ? "bg-surface text-text shadow-sm" : "text-text-muted hover:text-text"
              )}
            >
              {t(`masters.tabs.${s}`)}
            </button>
          ))}
        </div>
        {sub === "brands" ? <BrandsTab /> : <ModelsTab />}
      </DialogContent>
    </Dialog>
  )
}
