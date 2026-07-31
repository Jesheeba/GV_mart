import { useState } from "react"
import { useTranslation } from "react-i18next"
import { Loader2, Pencil, Plus, Star, Trash2 } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Dialog, DialogContent, DialogTitle } from "@/components/ui/dialog"
import { AddressForm } from "@/components/shared/AddressForm"
import { useToast } from "@/components/ui/toast-context"
import { useAddMyAddress, useDeleteMyAddress, useMyAddresses, useSetMyPrimaryAddress, useUpdateMyAddress } from "@/hooks/useCustomerApp"
import type { AddressRow } from "@/services/customerApp"

/**
 * Task 3 (2026-07-30) — shared address selection modal, reused across
 * Service Booking, AMC Booking, and Spare Enquiry (any future module needing
 * an address just mounts this + a "Change Address" trigger button). Reuses
 * the same AddressForm/hooks as the Profile page's own address management —
 * one CRUD path, not a second copy.
 */
export function AddressPickerModal({
  open,
  onOpenChange,
  orgId,
  customerId,
  selectedAddressId,
  onSelect,
}: {
  open: boolean
  onOpenChange: (open: boolean) => void
  orgId: string | undefined
  customerId: string | undefined
  selectedAddressId: string
  onSelect: (address: AddressRow) => void
}) {
  const { t } = useTranslation()
  const { toast } = useToast()
  const { data: addresses } = useMyAddresses(customerId)
  const [adding, setAdding] = useState(false)
  const [editingId, setEditingId] = useState<string | null>(null)
  const [confirmingDelete, setConfirmingDelete] = useState<string | null>(null)

  const addAddress = useAddMyAddress(orgId, customerId)
  const updateAddress = useUpdateMyAddress(customerId)
  const setPrimary = useSetMyPrimaryAddress(customerId)
  const deleteAddress = useDeleteMyAddress(customerId)

  function handleOpenChange(next: boolean) {
    onOpenChange(next)
    if (!next) {
      setAdding(false)
      setEditingId(null)
      setConfirmingDelete(null)
    }
  }

  return (
    <Dialog open={open} onOpenChange={handleOpenChange}>
      <DialogContent>
        <DialogTitle>{t("customerApp.addressPicker.title")}</DialogTitle>

        {(addresses ?? []).length === 0 && !adding ? (
          <p className="px-1 text-sm text-text-muted">{t("customerApp.addressPicker.noAddressesYet")}</p>
        ) : null}

        <ul className="space-y-2">
          {(addresses ?? []).map((a) =>
            editingId === a.id ? (
              <li key={a.id}>
                <AddressForm
                  initial={a}
                  isPending={updateAddress.isPending}
                  error={updateAddress.isError ? (updateAddress.error as Error).message : undefined}
                  onCancel={() => setEditingId(null)}
                  onSubmit={(values) => updateAddress.mutate({ addressId: a.id, input: values }, { onSuccess: () => setEditingId(null) })}
                />
              </li>
            ) : (
              <li
                key={a.id}
                className={`rounded-xl border px-3.5 py-2.5 transition-colors ${
                  a.id === selectedAddressId ? "border-accent bg-accent-soft" : "border-border"
                }`}
              >
                <div className="flex items-start gap-2">
                  <button
                    type="button"
                    onClick={() => {
                      onSelect(a)
                      handleOpenChange(false)
                    }}
                    className="min-w-0 flex-1 text-left"
                  >
                    <div className="flex items-center gap-1.5">
                      {a.is_primary ? (
                        <span className="flex items-center gap-1 rounded-full bg-accent-soft px-2 py-0.5 text-xs font-medium text-accent">
                          <Star className="size-3 fill-current" />
                          {t("customerApp.profile.primary")}
                        </span>
                      ) : null}
                      <span className="text-xs text-text-muted">{t(`customerApp.profile.address.${a.address_type}`)}</span>
                    </div>
                    <p className="text-sm text-text">{[a.door_no, a.flat_no, a.street_cross, a.area, a.pincode].filter(Boolean).join(", ")}</p>
                  </button>
                  <div className="flex shrink-0 items-center gap-1">
                    {!a.is_primary ? (
                      <Button
                        size="icon-xs"
                        variant="ghost"
                        title={t("customerApp.profile.setPrimary")}
                        disabled={setPrimary.isPending}
                        onClick={() => setPrimary.mutate(a.id, { onError: () => toast.error(t("common.actionFailed")) })}
                      >
                        <Star className="size-3.5" />
                      </Button>
                    ) : null}
                    <Button size="icon-xs" variant="ghost" title={t("customerApp.profile.edit")} onClick={() => setEditingId(a.id)}>
                      <Pencil className="size-3.5" />
                    </Button>
                    {!a.is_primary && confirmingDelete !== a.id ? (
                      <Button size="icon-xs" variant="ghost" title={t("common.remove")} onClick={() => setConfirmingDelete(a.id)}>
                        <Trash2 className="size-3.5 text-danger" />
                      </Button>
                    ) : null}
                  </div>
                </div>
                {confirmingDelete === a.id ? (
                  <div className="mt-2 flex items-center justify-end gap-2 border-t border-border pt-2 text-xs">
                    <button
                      type="button"
                      className="text-danger hover:underline"
                      disabled={deleteAddress.isPending}
                      onClick={() =>
                        deleteAddress.mutate(a.id, {
                          onSuccess: () => setConfirmingDelete(null),
                          onError: (err) => toast.error((err as Error).message || t("common.actionFailed")),
                        })
                      }
                    >
                      {deleteAddress.isPending ? <Loader2 className="size-3 animate-spin" /> : t("customerApp.profile.confirm")}
                    </button>
                    <button type="button" className="text-text-muted hover:underline" onClick={() => setConfirmingDelete(null)}>
                      {t("common.cancel")}
                    </button>
                  </div>
                ) : null}
              </li>
            )
          )}
        </ul>

        {adding ? (
          <AddressForm
            isPending={addAddress.isPending}
            error={addAddress.isError ? (addAddress.error as Error).message : undefined}
            onCancel={() => setAdding(false)}
            onSubmit={(values) =>
              addAddress.mutate(
                { input: values, makePrimary: (addresses ?? []).length === 0 },
                {
                  onSuccess: (row) => {
                    setAdding(false)
                    onSelect(row)
                    handleOpenChange(false)
                  },
                }
              )
            }
          />
        ) : !editingId ? (
          <Button type="button" variant="outline" onClick={() => setAdding(true)} className="w-full">
            <Plus className="size-3.5" />
            {t("customerApp.addressPicker.addNew")}
          </Button>
        ) : null}
      </DialogContent>
    </Dialog>
  )
}
