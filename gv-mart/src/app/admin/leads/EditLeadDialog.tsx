import { useEffect, useState } from "react"
import { useTranslation } from "react-i18next"
import { AlertTriangle, Loader2 } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Dialog, DialogContent, DialogDescription, DialogTitle } from "@/components/ui/dialog"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { useToast } from "@/components/ui/toast-context"
import { useProfile } from "@/hooks/useProfile"
import { useUpdateLeadDetails } from "@/hooks/useAutomation"
import { useLeadSourceOptions } from "@/hooks/useLeadSources"
import { useLeadProductTypeOptions } from "@/hooks/useLeadLists"
import { findDuplicateLeadOrCustomerByMobile, type LeadDuplicateMatch } from "@/services/automation"
import { normalizeOptionalIndianMobile } from "@/lib/mobile"
import { isLeadSourceEditAllowed } from "@/lib/lead-edit"

export type EditableLead = {
  id: string
  name: string
  mobile: string | null
  alternate_mobile: string | null
  address_text: string | null
  source: string
  product_type_key: string | null
  notes: string | null
}

const selectClass =
  "h-10 w-full rounded-xl border border-border bg-surface px-3 text-sm text-text outline-none focus-visible:border-ring focus-visible:ring-3 focus-visible:ring-ring/30 disabled:opacity-60"

/**
 * Edit Lead (#3, 2026-11-02). master, sales_admin and operation_admin only
 * (enforced again server-side by update_lead_details — see migration).
 *
 * owner_id is never shown here — it is not even a parameter of the save RPC,
 * so there is nothing in this form that could change it.
 *
 * source: when the lead is already a 'referral' lead, the field is shown
 * read-only with an explanation instead of a dropdown — flipping it away
 * would erase the basis for an already-earned technician finder credit
 * (see lib/lead-edit.ts / the migration's header comment). For every other
 * lead, 'referral' itself is left out of the dropdown so it can never be
 * set by hand here either.
 */
export function EditLeadDialog({ lead, open, onOpenChange, onDone }: { lead: EditableLead; open: boolean; onOpenChange: (open: boolean) => void; onDone?: () => void }) {
  const { t } = useTranslation()
  const { toast } = useToast()
  const { data: profile } = useProfile()
  const orgId = profile?.org_id
  const { activeSources, label: sourceLabel } = useLeadSourceOptions()
  const { activeProductTypes, label: productTypeLabel } = useLeadProductTypeOptions()
  const updateDetails = useUpdateLeadDetails()

  const [name, setName] = useState(lead.name)
  const [mobile, setMobile] = useState(lead.mobile ?? "")
  const [altMobile, setAltMobile] = useState(lead.alternate_mobile ?? "")
  const [address, setAddress] = useState(lead.address_text ?? "")
  const [source, setSource] = useState(lead.source)
  const [productType, setProductType] = useState(lead.product_type_key ?? "")
  const [notes, setNotes] = useState(lead.notes ?? "")

  const [errors, setErrors] = useState<Record<string, string>>({})
  const [duplicates, setDuplicates] = useState<LeadDuplicateMatch[]>([])
  const [acknowledgedDuplicates, setAcknowledgedDuplicates] = useState(false)
  const [checkingDuplicates, setCheckingDuplicates] = useState(false)

  // Reset local state whenever a different lead (or a fresh open) is given.
  useEffect(() => {
    if (!open) return
    setName(lead.name)
    setMobile(lead.mobile ?? "")
    setAltMobile(lead.alternate_mobile ?? "")
    setAddress(lead.address_text ?? "")
    setSource(lead.source)
    setProductType(lead.product_type_key ?? "")
    setNotes(lead.notes ?? "")
    setErrors({})
    setDuplicates([])
    setAcknowledgedDuplicates(false)
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [open, lead.id])

  const isReferral = lead.source === "referral"
  const sourceOptions = activeSources.filter((s) => s.key !== "referral")

  async function handleSave(skipDuplicateCheck = false) {
    const nextErrors: Record<string, string> = {}
    const trimmedName = name.trim()
    if (!trimmedName) nextErrors.name = t("leads.errors.nameRequired")

    const mobileResult = normalizeOptionalIndianMobile(mobile)
    if (!mobileResult.ok) nextErrors.mobile = t("leads.edit.errors.mobileInvalid")

    const altResult = normalizeOptionalIndianMobile(altMobile)
    if (!altResult.ok) nextErrors.alternateMobile = t("leads.edit.errors.mobileInvalid")

    if (!isLeadSourceEditAllowed(lead.source, source)) {
      nextErrors.source = t("leads.edit.errors.referralLocked")
    }

    setErrors(nextErrors)
    if (Object.keys(nextErrors).length > 0) return

    const normalizedMobile = mobileResult.ok ? mobileResult.value : null
    const normalizedAlt = altResult.ok ? altResult.value : null

    // WARN (never block) on a duplicate number, unless the user already said "save anyway".
    if (!skipDuplicateCheck && !acknowledgedDuplicates && orgId) {
      setCheckingDuplicates(true)
      try {
        const found: LeadDuplicateMatch[] = []
        if (normalizedMobile) found.push(...(await findDuplicateLeadOrCustomerByMobile(orgId, lead.id, normalizedMobile)))
        if (normalizedAlt && normalizedAlt !== normalizedMobile) found.push(...(await findDuplicateLeadOrCustomerByMobile(orgId, lead.id, normalizedAlt)))
        if (found.length > 0) {
          setDuplicates(found)
          setCheckingDuplicates(false)
          return
        }
      } catch {
        // Duplicate check failing must never block a save — it's a courtesy warning only.
      }
      setCheckingDuplicates(false)
    }

    try {
      await updateDetails.mutateAsync({
        leadId: lead.id,
        name: trimmedName,
        mobile: normalizedMobile,
        alternateMobile: normalizedAlt,
        addressText: address.trim() || null,
        source,
        productTypeKey: productType || null,
        notes: notes.trim() || null,
      })
      toast.success(t("leads.edit.saved"))
      onOpenChange(false)
      onDone?.()
    } catch (e) {
      toast.error(e instanceof Error && e.message ? e.message : t("common.actionFailed"))
    }
  }

  const busy = updateDetails.isPending || checkingDuplicates

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="max-w-lg">
        <DialogTitle>{t("leads.edit.title")}</DialogTitle>
        <DialogDescription>{t("leads.edit.subtitle")}</DialogDescription>
        <div className="grid grid-cols-1 gap-3 sm:grid-cols-2">
          <div className="space-y-1.5 sm:col-span-2">
            <Label htmlFor="edit-lead-name">{t("leads.new.name")}</Label>
            <Input id="edit-lead-name" value={name} onChange={(e) => setName(e.target.value)} />
            {errors.name ? <p className="text-xs text-danger">{errors.name}</p> : null}
          </div>
          <div className="space-y-1.5">
            <Label htmlFor="edit-lead-mobile">{t("leads.new.mobile")}</Label>
            <Input id="edit-lead-mobile" value={mobile} onChange={(e) => setMobile(e.target.value)} />
            {errors.mobile ? <p className="text-xs text-danger">{errors.mobile}</p> : null}
          </div>
          <div className="space-y-1.5">
            <Label htmlFor="edit-lead-alt-mobile">{t("leads.edit.alternateMobile")}</Label>
            <Input id="edit-lead-alt-mobile" value={altMobile} onChange={(e) => setAltMobile(e.target.value)} />
            {errors.alternateMobile ? <p className="text-xs text-danger">{errors.alternateMobile}</p> : null}
          </div>
          <div className="space-y-1.5 sm:col-span-2">
            <Label htmlFor="edit-lead-address">{t("leads.edit.address")}</Label>
            <textarea
              id="edit-lead-address"
              rows={2}
              value={address}
              onChange={(e) => setAddress(e.target.value)}
              className="w-full rounded-xl border border-border bg-surface px-3 py-2 text-sm text-text outline-none"
            />
          </div>
          <div className="space-y-1.5">
            <Label htmlFor="edit-lead-source">{t("leads.new.source")}</Label>
            {isReferral ? (
              <>
                <Input id="edit-lead-source" value={sourceLabel("referral")} disabled />
                <p className="text-xs text-text-muted">{t("leads.edit.referralLockedHint")}</p>
              </>
            ) : (
              <select id="edit-lead-source" value={source} onChange={(e) => setSource(e.target.value)} className={selectClass}>
                {sourceOptions.map((s) => (
                  <option key={s.key} value={s.key}>
                    {sourceLabel(s.key)}
                  </option>
                ))}
              </select>
            )}
            {errors.source ? <p className="text-xs text-danger">{errors.source}</p> : null}
          </div>
          <div className="space-y-1.5">
            <Label htmlFor="edit-lead-product-type">{t("leads.new.productCategory")}</Label>
            <select id="edit-lead-product-type" value={productType} onChange={(e) => setProductType(e.target.value)} className={selectClass}>
              <option value="">{t("service.filters.all")}</option>
              {activeProductTypes.map((p) => (
                <option key={p.key} value={p.key}>
                  {productTypeLabel(p.key)}
                </option>
              ))}
            </select>
          </div>
          <div className="space-y-1.5 sm:col-span-2">
            <Label htmlFor="edit-lead-notes">{t("leads.new.notes")}</Label>
            <textarea
              id="edit-lead-notes"
              rows={3}
              value={notes}
              onChange={(e) => setNotes(e.target.value)}
              className="w-full rounded-xl border border-border bg-surface px-3 py-2 text-sm text-text outline-none"
            />
          </div>
        </div>

        {duplicates.length > 0 ? (
          <div className="flex items-start gap-2 rounded-xl border border-warning/40 bg-warning/10 px-3 py-2.5 text-sm text-text">
            <AlertTriangle className="mt-0.5 size-4 shrink-0 text-warning" />
            <div className="space-y-1">
              <p>{t("leads.edit.duplicateWarning")}</p>
              <ul className="list-inside list-disc text-xs text-text-muted">
                {duplicates.map((d) => (
                  <li key={`${d.kind}-${d.id}`}>{t(`leads.edit.duplicateKind.${d.kind}`, { name: d.name })}</li>
                ))}
              </ul>
            </div>
          </div>
        ) : null}

        <div className="flex justify-end gap-2">
          <Button variant="ghost" onClick={() => onOpenChange(false)} disabled={busy}>
            {t("common.cancel")}
          </Button>
          {duplicates.length > 0 ? (
            <Button
              variant="accent"
              disabled={busy}
              onClick={() => {
                setAcknowledgedDuplicates(true)
                setDuplicates([])
                void handleSave(true)
              }}
            >
              {busy ? <Loader2 className="size-3.5 animate-spin" /> : t("leads.edit.saveAnyway")}
            </Button>
          ) : (
            <Button variant="accent" onClick={() => handleSave()} disabled={busy}>
              {busy ? <Loader2 className="size-3.5 animate-spin" /> : t("common.save")}
            </Button>
          )}
        </div>
      </DialogContent>
    </Dialog>
  )
}
