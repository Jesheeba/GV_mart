import { useState } from "react"
import { useTranslation } from "react-i18next"
import { Loader2 } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Dialog, DialogContent, DialogDescription, DialogTitle } from "@/components/ui/dialog"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { useCreateCustomer, useDuplicateContactWarning } from "@/hooks/useCustomers"
import { existingCustomerMatch, quickAddCustomerSchema } from "@/lib/referrer"

export type QuickAddedCustomer = { id: string; name: string; mobile: string }

/**
 * Referral sources (2026-11-26): "+ Add new customer" from a referrer search.
 * Name + Mobile + Area (optional) only — the rest of the profile is filled in
 * later from the customer page. Creates a real customer via the same
 * create_customer_with_details RPC the full form uses (no new server path).
 * If the mobile already belongs to a customer, offers that one instead of
 * creating a duplicate.
 *
 * Buttons are type="button": this dialog is opened from inside other <form>s
 * (New Lead, New Customer) and must never submit them.
 */
export function QuickAddCustomerDialog({
  open,
  onOpenChange,
  orgId,
  initialText = "",
  onPicked,
}: {
  open: boolean
  onOpenChange: (open: boolean) => void
  orgId: string | undefined
  /** What the user had typed in the search — prefills Mobile if it is digits, else Name. Mount fresh per open so it applies. */
  initialText?: string
  onPicked: (customer: QuickAddedCustomer) => void
}) {
  const { t } = useTranslation()
  const typedIsPhone = /^\d+$/.test(initialText.trim())
  const [name, setName] = useState(typedIsPhone ? "" : initialText.trim())
  const [mobile, setMobile] = useState(typedIsPhone ? initialText.trim().slice(0, 10) : "")
  const [area, setArea] = useState("")
  const [errors, setErrors] = useState<{ name?: string; mobile?: string; form?: string }>({})
  const createCustomer = useCreateCustomer()
  const duplicates = useDuplicateContactWarning(orgId, mobile.trim())
  const existing = existingCustomerMatch(duplicates.data)

  function reset() {
    setName("")
    setMobile("")
    setArea("")
    setErrors({})
  }

  function finish(customer: QuickAddedCustomer) {
    onPicked(customer)
    reset()
    onOpenChange(false)
  }

  async function handleSave() {
    const parsed = quickAddCustomerSchema.safeParse({ name, mobile, area })
    if (!parsed.success) {
      const flat = parsed.error.flatten().fieldErrors
      setErrors({ name: flat.name?.[0], mobile: flat.mobile?.[0] })
      return
    }
    if (!orgId) return
    setErrors({})
    try {
      const id = await createCustomer.mutateAsync({
        orgId,
        members: [{ name: parsed.data.name, mobile: parsed.data.mobile, isPrimary: true }],
        address: { area: parsed.data.area || undefined },
      })
      finish({ id: id as string, name: parsed.data.name, mobile: parsed.data.mobile })
    } catch (e) {
      setErrors({ form: e instanceof Error && e.message ? e.message : t("common.actionFailed") })
    }
  }

  const busy = createCustomer.isPending

  return (
    <Dialog
      open={open}
      onOpenChange={(next) => {
        if (!next) reset()
        onOpenChange(next)
      }}
    >
      <DialogContent className="max-w-md">
        <DialogTitle>{t("referrer.quickAdd.title")}</DialogTitle>
        <DialogDescription>{t("referrer.quickAdd.subtitle")}</DialogDescription>
        <div className="space-y-3">
          <div className="space-y-1.5">
            <Label htmlFor="quick-add-customer-name">{t("referrer.quickAdd.name")}</Label>
            <Input id="quick-add-customer-name" autoFocus value={name} onChange={(e) => setName(e.target.value)} aria-invalid={!!errors.name} />
            {errors.name ? <p className="text-xs text-danger">{t(errors.name)}</p> : null}
          </div>
          <div className="space-y-1.5">
            <Label htmlFor="quick-add-customer-mobile">{t("referrer.quickAdd.mobile")}</Label>
            <Input
              id="quick-add-customer-mobile"
              type="tel"
              inputMode="tel"
              maxLength={10}
              className="max-w-40"
              value={mobile}
              onChange={(e) => setMobile(e.target.value.replace(/\D/g, ""))}
              aria-invalid={!!errors.mobile}
            />
            {errors.mobile ? <p className="text-xs text-danger">{t(errors.mobile)}</p> : null}
          </div>
          <div className="space-y-1.5">
            <Label htmlFor="quick-add-customer-area">{t("referrer.quickAdd.area")}</Label>
            <Input id="quick-add-customer-area" value={area} onChange={(e) => setArea(e.target.value)} />
          </div>
          {existing ? (
            <div role="status" className="space-y-2 rounded-xl border border-warning/40 bg-warning/10 p-3 text-sm">
              <p>{t("referrer.quickAdd.existingFound", { name: existing.name })}</p>
              <Button type="button" variant="outline" size="sm" onClick={() => finish({ id: existing.id, name: existing.name, mobile: existing.mobile ?? mobile })}>
                {t("referrer.quickAdd.useExisting", { name: existing.name })}
              </Button>
            </div>
          ) : null}
          {errors.form ? (
            <p role="alert" className="text-xs text-danger">
              {errors.form}
            </p>
          ) : null}
        </div>
        <div className="flex justify-end gap-2">
          <Button type="button" variant="ghost" onClick={() => onOpenChange(false)} disabled={busy}>
            {t("common.cancel")}
          </Button>
          {/* With an existing match, creating a second record is the wrong default — the user picks "Use …" above. */}
          <Button type="button" variant="accent" onClick={() => void handleSave()} disabled={busy || !!existing || duplicates.isFetching}>
            {busy ? <Loader2 className="size-3.5 animate-spin" /> : t("referrer.quickAdd.save")}
          </Button>
        </div>
      </DialogContent>
    </Dialog>
  )
}
