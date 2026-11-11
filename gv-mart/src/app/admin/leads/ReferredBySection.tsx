import { useEffect, useRef, useState } from "react"
import { useTranslation } from "react-i18next"
import { Search } from "lucide-react"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { Autocomplete } from "@/components/shared/Autocomplete"
import { ReferrerPicker } from "@/components/shared/ReferrerPicker"
import { useCustomerAutocomplete } from "@/hooks/useCustomers"

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
 * - referral: free-text name/phone (not in the system yet).
 * - customer_app: existing-customer search (prefills name/phone, no new column —
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
  allowTechnicianOrStaff?: boolean
}) {
  const { t } = useTranslation()
  const rawMode = MODE_BY_SOURCE[source] ?? "none"
  const mode = (rawMode === "technician" || rawMode === "staff") && !allowTechnicianOrStaff ? "none" : rawMode

  const [customerSearch, setCustomerSearch] = useState("")
  const customerAutocomplete = useCustomerAutocomplete(orgId, customerSearch)

  // Switching Source away from a mode clears that mode's own fields, so
  // stale data from a source the user backed out of never gets submitted.
  const prevMode = useRef(mode)
  useEffect(() => {
    if (prevMode.current !== mode) {
      if (prevMode.current === "technician" || prevMode.current === "staff") onReferredByUserIdChange("")
      if (prevMode.current === "other" || prevMode.current === "customer") {
        onReferredByNameChange("")
        onReferredByPhoneChange("")
      }
      setCustomerSearch("")
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

      {mode === "customer" ? (
        <Autocomplete
          id="lead-referred-by-customer"
          value={referredByName && !customerSearch ? (referredByPhone ? `${referredByName} · ${referredByPhone}` : referredByName) : customerSearch}
          onChange={(v) => {
            setCustomerSearch(v)
            onReferredByNameChange("")
            onReferredByPhoneChange("")
          }}
          suggestions={customerAutocomplete.data ?? []}
          loading={customerAutocomplete.isFetching}
          placeholder={t("leads.referredBy.searchCustomerPlaceholder")}
          icon={<Search className="size-4" />}
          emptyMessage={t("common.noData")}
          getKey={(c) => c.id}
          getLabel={(c) => (
            <span>
              <span className="font-medium">{c.name}</span> <span className="text-text-muted">{c.mobile}</span>
            </span>
          )}
          onSelect={(c) => {
            onReferredByNameChange(c.name)
            onReferredByPhoneChange(c.mobile ?? "")
            setCustomerSearch("")
          }}
        />
      ) : null}

      {mode === "other" ? (
        <div className="grid grid-cols-2 gap-2">
          <Input
            aria-label={t("leads.new.referredByName")}
            placeholder={t("leads.new.referredByName")}
            className="h-8 px-2.5"
            value={referredByName}
            onChange={(e) => onReferredByNameChange(e.target.value)}
          />
          <Input
            aria-label={t("leads.new.referredByPhone")}
            type="tel"
            placeholder={t("leads.new.referredByPhone")}
            className="h-8 px-2.5"
            value={referredByPhone}
            onChange={(e) => onReferredByPhoneChange(e.target.value)}
          />
        </div>
      ) : null}
    </div>
  )
}
