import { useEffect, useRef, useState } from "react"
import { useTranslation } from "react-i18next"
import { Label } from "@/components/ui/label"
import { ReferrerPicker } from "@/components/shared/ReferrerPicker"
import { ReferrerField } from "@/components/shared/ReferrerField"
import type { ReferrerKind } from "@/lib/referrer"

type Mode = "none" | "technician" | "staff" | "customer" | "other"

/** Source key -> what the Referred-by block shows. Anything not listed hides it entirely. */
const MODE_BY_SOURCE: Record<string, Mode> = {
  field: "technician", // seeded source label is "Technician"
  reporting_staff: "staff",
  referral: "other",
  customer_app: "customer",
}

/**
 * Referred-by redesign (2026-11-11, v2) — fully driven by Source, no separate
 * "who referred this" choice to make: pick Source and the right field just
 * appears, pick a different one and it's gone.
 * - field ("Technician"): technician-only picker (referredByUserId).
 * - reporting_staff ("Reporting staff"): staff-only picker, same picker UI.
 * - referral: full referrer chooser (ReferrerField) — technician, sales
 *   person/staff, existing customer (with quick-add) or someone else.
 *   Referral sources batch 2026-11-26 (owner): supersedes the free-text-only box.
 * - customer_app: existing-customer search + quick-add (prefills name/phone —
 *   an app lead is by construction from an existing customer).
 * - every other source: nothing shown.
 */
export function ReferredBySection({
  orgId,
  source,
  referredByUserId,
  onReferredByUserIdChange,
  referredByName,
  onReferredByNameChange,
  referredByPhone,
  onReferredByPhoneChange,
  referredByCustomerId,
  onReferredByCustomerIdChange,
  // Technician/staff attribution (referredByUserId) is a bonus-eligible,
  // set-once-at-creation field (see referral_bonus_rates/_carry_over_lead_referral)
  // — LeadDetailFieldsCard's edit form doesn't touch it, so it hides that
  // picker there rather than show one that silently does nothing on save.
  allowTechnicianOrStaff = true,
}: {
  orgId: string | undefined
  source: string
  referredByUserId: string
  onReferredByUserIdChange: (next: string) => void
  referredByName: string
  onReferredByNameChange: (next: string) => void
  referredByPhone: string
  onReferredByPhoneChange: (next: string) => void
  referredByCustomerId: string
  onReferredByCustomerIdChange: (next: string) => void
  allowTechnicianOrStaff?: boolean
}) {
  const { t } = useTranslation()
  const rawMode = MODE_BY_SOURCE[source] ?? "none"
  const mode = (rawMode === "technician" || rawMode === "staff") && !allowTechnicianOrStaff ? "none" : rawMode

  // Which referrer kinds the Referral / Customer app sources offer. Technician/staff
  // stay out of the edit card (allowTechnicianOrStaff=false) — set-once at creation.
  const kinds: ReferrerKind[] =
    mode === "customer" ? ["customer"] : allowTechnicianOrStaff ? ["other", "technician", "staff", "customer"] : ["other", "customer"]
  // A customer referrer is saved as referred_by_customer_id (+ a name/phone copy for display).
  const [kind, setKind] = useState<ReferrerKind>(referredByCustomerId ? "customer" : kinds[0])

  // Switching Source away from a mode clears that mode's own fields, so
  // stale data from a source the user backed out of never gets submitted.
  const prevMode = useRef(mode)
  useEffect(() => {
    if (prevMode.current !== mode) {
      if (referredByUserId) onReferredByUserIdChange("")
      if (referredByName) onReferredByNameChange("")
      if (referredByPhone) onReferredByPhoneChange("")
      if (referredByCustomerId) onReferredByCustomerIdChange("")
      setKind(kinds[0])
      prevMode.current = mode
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [mode])

  if (mode === "none") return null

  return (
    <div className="space-y-0.5">
      <Label>{t("leads.new.referredBy")}</Label>

      {mode === "technician" ? (
        <ReferrerPicker id="lead-referred-by-technician" orgId={orgId} kindFilter="technician" label={t("leads.referredBy.pickTechnician")} value={referredByUserId} onChange={onReferredByUserIdChange} />
      ) : null}

      {mode === "staff" ? (
        <ReferrerPicker id="lead-referred-by-staff" orgId={orgId} kindFilter="staff" label={t("leads.referredBy.pickStaff")} value={referredByUserId} onChange={onReferredByUserIdChange} />
      ) : null}

      {mode === "other" || mode === "customer" ? (
        <ReferrerField
          idPrefix="lead-referred-by"
          orgId={orgId}
          kinds={kinds}
          value={{ kind, userId: referredByUserId, customerId: referredByCustomerId, name: referredByName, phone: referredByPhone }}
          onChange={(next) => {
            setKind(next.kind)
            if (next.customerId !== referredByCustomerId) onReferredByCustomerIdChange(next.customerId)
            if (next.userId !== referredByUserId) onReferredByUserIdChange(next.userId)
            if (next.name !== referredByName) onReferredByNameChange(next.name)
            if (next.phone !== referredByPhone) onReferredByPhoneChange(next.phone)
          }}
        />
      ) : null}
    </div>
  )
}
