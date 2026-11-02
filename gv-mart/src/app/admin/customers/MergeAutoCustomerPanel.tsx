import { useState } from "react"
import { useTranslation } from "react-i18next"
import { CheckCircle2, Loader2, Merge, TriangleAlert } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { Autocomplete } from "@/components/shared/Autocomplete"
import { useAdminMergeAutoCustomer, useCustomerAutocomplete } from "@/hooks/useCustomers"

const MERGE_ERROR_KEYS = new Set([
  "reason_required",
  "same_customer",
  "from_customer_not_found",
  "to_customer_not_found",
  "from_customer_not_auto_created",
  "from_customer_already_archived",
  "from_customer_not_linked",
  "to_customer_is_test",
  "to_customer_archived",
  "to_customer_already_linked",
  "from_customer_has_records",
])

/**
 * Master-only. Shown only for an auto-created ('app') customer -- the one case
 * admin_link_customer_google_account refuses (the auth user already has a profile, created by
 * customer_auto_onboard itself). Moves that sign-in onto an existing, real customer record
 * instead -- for a returning customer who signed in via Google before staff found their real
 * record. Refuses server-side unless this customer has zero invoices/tickets/AMC/rental/
 * warranty/quotation data and the target isn't already linked (see
 * 20261130100003_merge_auto_customer.sql). Renders bare, same convention as
 * GoogleAccountLinkPanel.
 */
export function MergeAutoCustomerPanel({ orgId, customerId, customerName }: { orgId: string | undefined; customerId: string; customerName: string }) {
  const { t } = useTranslation()
  const [search, setSearch] = useState("")
  const [targetId, setTargetId] = useState("")
  const [targetLabel, setTargetLabel] = useState("")
  const [reason, setReason] = useState("")
  const [done, setDone] = useState(false)
  const autocomplete = useCustomerAutocomplete(orgId, search)
  const merge = useAdminMergeAutoCustomer(customerId)

  function submit() {
    if (!window.confirm(t("customers.detail.mergeAuto.confirm", { from: customerName, to: targetLabel }))) return
    setDone(false)
    merge.mutate(
      { toCustomerId: targetId, reason },
      {
        onSuccess: () => {
          setTargetId("")
          setTargetLabel("")
          setSearch("")
          setReason("")
          setDone(true)
        },
      }
    )
  }

  function errorMessage(error: unknown) {
    const code = (error as Error)?.message ?? ""
    const key = [...MERGE_ERROR_KEYS].find((k) => code.includes(k))
    return key ? t(`customers.detail.mergeAuto.errors.${key}`) : t("common.actionFailed")
  }

  if (done) {
    return (
      <p className="flex items-center gap-1.5 rounded-xl bg-success/10 px-3.5 py-2.5 text-sm text-success">
        <CheckCircle2 className="size-4" /> {t("customers.detail.mergeAuto.success")}
      </p>
    )
  }

  return (
    <div className="space-y-3 border-t border-border pt-3">
      <div className="flex items-center gap-2">
        <Merge className="size-4 text-text-muted" />
        <h3 className="text-sm font-bold text-text">{t("customers.detail.mergeAuto.title")}</h3>
      </div>
      <p className="text-xs text-text-muted">{t("customers.detail.mergeAuto.hint")}</p>

      <div className="space-y-1.5">
        <Label>{t("customers.detail.mergeAuto.targetLabel")}</Label>
        <Autocomplete
          value={targetId ? targetLabel : search}
          onChange={(v) => {
            setSearch(v)
            setTargetId("")
          }}
          suggestions={(autocomplete.data ?? []).filter((c) => c.id !== customerId)}
          loading={autocomplete.isFetching}
          emptyMessage={t("common.noData")}
          getKey={(c) => c.id}
          getLabel={(c) => (
            <span>
              <span className="font-medium">{c.name}</span> <span className="text-text-muted">{c.mobile}</span>
            </span>
          )}
          onSelect={(c) => {
            setTargetId(c.id)
            setTargetLabel(c.mobile ? `${c.name} · ${c.mobile}` : c.name)
          }}
        />
      </div>

      <div className="space-y-1">
        <Label htmlFor="merge-auto-reason">{t("customers.detail.mergeAuto.reasonLabel")}</Label>
        <Input id="merge-auto-reason" value={reason} onChange={(e) => setReason(e.target.value)} placeholder={t("customers.detail.mergeAuto.reasonPlaceholder")} />
      </div>

      <Button type="button" size="sm" disabled={!targetId || !reason.trim() || merge.isPending} onClick={submit}>
        {merge.isPending ? <Loader2 className="size-3.5 animate-spin" /> : <Merge className="size-3.5" />}
        {t("customers.detail.mergeAuto.action")}
      </Button>
      {merge.error ? (
        <p className="flex items-center gap-1.5 text-xs text-danger">
          <TriangleAlert className="size-3.5 shrink-0" /> {errorMessage(merge.error)}
        </p>
      ) : null}
    </div>
  )
}
