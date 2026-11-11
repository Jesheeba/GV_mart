import { useState } from "react"
import { useTranslation } from "react-i18next"
import { Search } from "lucide-react"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { Button } from "@/components/ui/button"
import { Autocomplete } from "@/components/shared/Autocomplete"
import { ReferrerPicker } from "@/components/shared/ReferrerPicker"
import { useCustomerAutocomplete } from "@/hooks/useCustomers"
import { cn } from "@/lib/utils"

/** Sources where "who referred this lead" is worth asking about at all. */
export const REFERRAL_RELEVANT_SOURCES = ["referral", "customer_app"]

type Mode = "none" | "technician" | "customer" | "other"

/**
 * Referred-by redesign (2026-11-11) — one block, shape depends on Source:
 * - source = referral / customer_app: a 3-way picker shows up — pick a
 *   technician/staff (bonus-eligible, referredByUserId), search an existing
 *   customer (prefills the free-text name/phone below — no new column), or
 *   type a name/phone for someone not in the system yet.
 * - customer_app leads are, by construction, from an existing customer —
 *   the picker defaults to "Existing customer" so staff isn't left typing a
 *   name the app already has on file.
 * - any other source: hidden, unless the lead already carries referral data
 *   (so editing an older lead never silently drops what's there).
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
  // option rather than show a picker that silently does nothing on save.
  allowTechnician = true,
}: {
  orgId: string | undefined
  source: string
  referredByUserId: string
  onReferredByUserIdChange: (next: string) => void
  referredByName: string
  onReferredByNameChange: (next: string) => void
  referredByPhone: string
  onReferredByPhoneChange: (next: string) => void
  allowTechnician?: boolean
}) {
  const { t } = useTranslation()
  const hasExistingData = !!referredByUserId || !!referredByName || !!referredByPhone
  const relevant = REFERRAL_RELEVANT_SOURCES.includes(source) || hasExistingData

  const [mode, setMode] = useState<Mode>(() => {
    if (referredByUserId) return "technician"
    if (referredByName || referredByPhone) return "other"
    return source === "customer_app" ? "customer" : "none"
  })
  const [customerSearch, setCustomerSearch] = useState("")
  const customerAutocomplete = useCustomerAutocomplete(orgId, customerSearch)

  if (!relevant) return null

  function switchMode(next: Mode) {
    setMode(next)
    // Each mode writes to its own field(s) only — clear the others so a
    // stale value from a mode the user backed out of never gets submitted.
    if (next !== "technician") onReferredByUserIdChange("")
    if (next !== "other" && next !== "customer") {
      onReferredByNameChange("")
      onReferredByPhoneChange("")
    }
    if (next !== "customer") setCustomerSearch("")
  }

  return (
    <div className="space-y-1.5 sm:col-span-2">
      <Label>{t("leads.new.referredBy")}</Label>
      <div className="flex flex-wrap gap-1.5">
        {(
          [
            allowTechnician ? ({ key: "technician", label: t("leads.referredBy.technicianOrStaff") } as const) : null,
            { key: "customer", label: t("leads.referredBy.existingCustomer") } as const,
            { key: "other", label: t("leads.referredBy.someoneElse") } as const,
          ].filter((x): x is { key: Mode; label: string } => x !== null)
        ).map(({ key, label }) => (
          <button
            key={key}
            type="button"
            onClick={() => switchMode(key)}
            className={cn(
              "rounded-full border px-3 py-1 text-xs font-semibold",
              mode === key ? "border-accent bg-accent text-accent-foreground" : "border-border text-text hover:bg-surface-alt"
            )}
          >
            {label}
          </button>
        ))}
        {mode !== "none" ? (
          <Button type="button" size="sm" variant="ghost" onClick={() => switchMode("none")}>
            {t("common.none")}
          </Button>
        ) : null}
      </div>

      {mode === "technician" ? (
        <ReferrerPicker id="lead-referred-by-technician" orgId={orgId} label={t("leads.referredBy.pickTechnicianOrStaff")} value={referredByUserId} onChange={onReferredByUserIdChange} />
      ) : null}

      {mode === "customer" ? (
        <div className="space-y-1">
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
        </div>
      ) : null}

      {mode === "other" ? (
        <div className="grid grid-cols-2 gap-3">
          <Input aria-label={t("leads.new.referredByName")} placeholder={t("leads.new.referredByName")} value={referredByName} onChange={(e) => onReferredByNameChange(e.target.value)} />
          <Input
            aria-label={t("leads.new.referredByPhone")}
            type="tel"
            placeholder={t("leads.new.referredByPhone")}
            value={referredByPhone}
            onChange={(e) => onReferredByPhoneChange(e.target.value)}
          />
        </div>
      ) : null}
    </div>
  )
}
