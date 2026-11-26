import { useTranslation } from "react-i18next"
import { QuickAddInline } from "@/components/shared/QuickAddInline"
import { useCreateSupplier, useSuppliersList } from "@/hooks/useSuppliers"
import { findByLabel } from "@/lib/quickAdd"

/**
 * "+ Add new" under a Supplier dropdown (PO + Bill entry, 2026-11-26). Name
 * only; contact/WhatsApp are filled later in Suppliers. A name that already
 * exists (any case/spacing) is selected instead of creating a duplicate.
 * suppliers RLS (is_ops_staff) already allows the Purchase page's roles.
 */
export function SupplierQuickAdd({ orgId, onAdded }: { orgId: string | undefined; onAdded: (supplierId: string) => void }) {
  const { t } = useTranslation()
  const { data: suppliers } = useSuppliersList(orgId)
  const create = useCreateSupplier()
  if (!orgId) return null
  return (
    <div className="space-y-0.5">
      <QuickAddInline
        maxLength={120}
        placeholder={t("purchase.quickAdd.supplierPlaceholder")}
        onAdd={async (name) => {
          const existing = findByLabel(suppliers ?? [], (s) => s.name, name)
          if (existing) return onAdded(existing.id)
          try {
            onAdded((await create.mutateAsync({ org_id: orgId, name })).id)
          } catch {
            throw new Error(t("common.quickAddFailed"))
          }
        }}
      />
    </div>
  )
}
