import { useTranslation } from "react-i18next"
import { QuickAddInline } from "@/components/shared/QuickAddInline"
import { useProfile } from "@/hooks/useProfile"
import { useQuickAddLeadOption } from "@/hooks/useMasters"
import type { LeadOptionList } from "@/services/masters"

const PLACEHOLDER: Record<LeadOptionList, string> = {
  source: "leads.quickAdd.sourcePlaceholder",
  kind: "leads.quickAdd.kindPlaceholder",
  product_type: "leads.quickAdd.productTypePlaceholder",
}

/** "+ Add new" under a lead Source / Kind / Product type dropdown; `onAdded` gets the option key to select. Hidden for roles the RPC would refuse. */
export function LeadOptionQuickAdd({ list, onAdded }: { list: LeadOptionList; onAdded: (key: string) => void }) {
  const { t } = useTranslation()
  const { data: profile } = useProfile()
  const add = useQuickAddLeadOption(list)
  if (profile?.role !== "master" && profile?.role !== "sales_admin") return null
  return (
    <QuickAddInline
      placeholder={t(PLACEHOLDER[list])}
      onAdd={async (label) => {
        try {
          onAdded(await add.mutateAsync(label))
        } catch (e) {
          const err = e as { message?: string; code?: string }
          if (err.message === "archived") throw new Error(t("leads.quickAdd.archived"))
          if (err.code === "42501") throw new Error(t("leads.quickAdd.notAllowed"))
          throw new Error(t("common.quickAddFailed"))
        }
      }}
    />
  )
}
