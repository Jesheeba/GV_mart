import { useState } from "react"
import { useTranslation } from "react-i18next"
import { Search, UserPlus, X } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { Autocomplete } from "@/components/shared/Autocomplete"
import { ReferrerPicker } from "@/components/shared/ReferrerPicker"
import { QuickAddCustomerDialog } from "@/components/shared/QuickAddCustomerDialog"
import { useCustomerAutocomplete } from "@/hooks/useCustomers"
import { REFERRER_KINDS, switchReferrerKind, type ReferrerKind, type ReferrerValue } from "@/lib/referrer"

/**
 * Referral sources everywhere (build-docs/features/referral-sources.md):
 * one "Referred by" control for every screen — pick who referred
 * (Technician / Sales person-staff / Existing customer / Someone else),
 * then the matching input appears. Existing customer has a quick-add for
 * referrers not in the system yet.
 *
 * `kinds` narrows the chooser (e.g. a screen that can't persist a
 * technician/staff referrer). With a single kind the chooser is hidden.
 * `excludeCustomerId` keeps the customer being billed/created out of the
 * results — nobody refers themselves (the DB rejects it too).
 */
export function ReferrerField({
  idPrefix,
  orgId,
  value,
  onChange,
  kinds = REFERRER_KINDS,
  excludeCustomerId,
  label,
}: {
  idPrefix: string
  orgId: string | undefined
  value: ReferrerValue
  onChange: (next: ReferrerValue) => void
  kinds?: readonly ReferrerKind[]
  excludeCustomerId?: string | null
  label?: string
}) {
  const { t } = useTranslation()
  const [search, setSearch] = useState("")
  const [quickAddOpen, setQuickAddOpen] = useState(false)
  const kind = kinds.includes(value.kind) ? value.kind : kinds[0]
  const customerResults = useCustomerAutocomplete(kind === "customer" ? orgId : undefined, search)
  const suggestions = (customerResults.data ?? []).filter((c) => c.id !== excludeCustomerId)
  const showChooser = kinds.length > 1

  return (
    <div className="space-y-1.5">
      {showChooser ? (
        <div className="space-y-1">
          <label htmlFor={`${idPrefix}-kind`} className="block text-xs font-medium text-text-muted">
            {label ?? t("referrer.label")}
          </label>
          <select
            id={`${idPrefix}-kind`}
            value={kind}
            onChange={(e) => {
              setSearch("")
              onChange(switchReferrerKind(value, e.target.value as ReferrerKind))
            }}
            className="h-10 w-full rounded-xl border border-border bg-surface px-3 text-sm text-text outline-none sm:max-w-xs"
          >
            {kinds.map((k) => (
              <option key={k} value={k}>
                {t(`referrer.kind.${k}`)}
              </option>
            ))}
          </select>
        </div>
      ) : null}

      {kind === "technician" || kind === "staff" ? (
        <ReferrerPicker
          id={`${idPrefix}-${kind}`}
          orgId={orgId}
          kindFilter={kind}
          label={t(kind === "technician" ? "leads.referredBy.pickTechnician" : "referrer.pickStaff")}
          value={value.userId}
          onChange={(userId) => onChange({ ...value, kind, userId })}
        />
      ) : null}

      {kind === "customer" ? (
        // A name without an id = a customer referrer saved before referred_by_customer_id existed; still show it.
        value.customerId || value.name.trim() ? (
          <div className="flex items-center gap-2 text-sm">
            <span className="font-medium">{value.name}</span>
            {value.phone ? <span className="text-text-muted">{value.phone}</span> : null}
            <Button
              type="button"
              variant="ghost"
              size="icon-xs"
              aria-label={t("referrer.clearCustomer")}
              onClick={() => onChange({ ...value, customerId: "", name: "", phone: "" })}
            >
              <X />
            </Button>
          </div>
        ) : (
          <div className="space-y-1">
            <Autocomplete
              id={`${idPrefix}-customer`}
              value={search}
              onChange={setSearch}
              suggestions={suggestions}
              loading={customerResults.isFetching}
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
                onChange({ ...value, kind, customerId: c.id, name: c.name, phone: c.mobile ?? "" })
                setSearch("")
              }}
              onCreate={() => setQuickAddOpen(true)}
              createLabel={t("referrer.addNewCustomer")}
            />
            <Button type="button" variant="outline" size="xs" onClick={() => setQuickAddOpen(true)}>
              <UserPlus data-icon="inline-start" />
              {t("referrer.addNewCustomer")}
            </Button>
          </div>
        )
      ) : null}

      {kind === "other" ? (
        <div className="grid grid-cols-2 gap-2">
          <Input
            aria-label={t("leads.new.referredByName")}
            placeholder={t("leads.new.referredByName")}
            className="h-8 px-2.5"
            maxLength={120}
            value={value.name}
            onChange={(e) => onChange({ ...value, kind, name: e.target.value })}
          />
          <Input
            aria-label={t("leads.new.referredByPhone")}
            type="tel"
            inputMode="tel"
            maxLength={20}
            placeholder={t("leads.new.referredByPhone")}
            className="h-8 max-w-40 px-2.5"
            value={value.phone}
            onChange={(e) => onChange({ ...value, kind, phone: e.target.value })}
          />
        </div>
      ) : null}

      {/* Mounted per open so the typed search text prefills it fresh each time. */}
      {quickAddOpen ? (
        <QuickAddCustomerDialog
          open
          onOpenChange={setQuickAddOpen}
          orgId={orgId}
          initialText={search}
          onPicked={(c) => {
            if (c.id === excludeCustomerId) return
            onChange({ ...value, kind: "customer", customerId: c.id, name: c.name, phone: c.mobile })
            setSearch("")
          }}
        />
      ) : null}
    </div>
  )
}
