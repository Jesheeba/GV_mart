import { useState } from "react"
import { useTranslation } from "react-i18next"
import { Loader2, Paperclip } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Card } from "@/components/ui/card"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { useToast } from "@/components/ui/toast-context"
import { useProfile } from "@/hooks/useProfile"
import { useUpdateLeadDetailFields } from "@/hooks/useAutomation"
import { leadDocumentSignedUrl, uploadLeadDocument, validateLeadDocument } from "@/services/leadDocuments"
import type { LeadListItem } from "@/services/automation"
import { ReferredBySection } from "./ReferredBySection"

/**
 * Lead Dashboard Enhancement, feature 4 — customer requirement, special
 * description, user source, budget, when-needed, TDS, and the optional
 * report/document upload. See build-docs/features/lead-detail-fields.md.
 * Plain columns (not trigger-gated like assigned_to), so a direct update
 * through leads_update_sales RLS is enough — no new RPC for these fields.
 */
export function LeadDetailFieldsCard({ lead }: { lead: LeadListItem }) {
  const { t } = useTranslation()
  const { toast } = useToast()
  const { data: profile } = useProfile()
  const update = useUpdateLeadDetailFields()
  const [editing, setEditing] = useState(false)
  const [uploading, setUploading] = useState(false)
  const [form, setForm] = useState({
    customer_requirement: lead.customer_requirement ?? "",
    special_description: lead.special_description ?? "",
    budget: lead.budget != null ? String(lead.budget) : "",
    when_needed: lead.when_needed ?? "",
    tds_status: lead.tds_status ?? "",
    referred_by_name: lead.referred_by_name ?? "",
    referred_by_phone: lead.referred_by_phone ?? "",
  })
  const budgetInvalid = form.budget !== "" && Number(form.budget) < 0

  async function save() {
    if (budgetInvalid) return
    try {
      await update.mutateAsync({
        leadId: lead.id,
        patch: {
          customer_requirement: form.customer_requirement.trim() || null,
          special_description: form.special_description.trim() || null,
          budget: form.budget !== "" ? Number(form.budget) : null,
          when_needed: form.when_needed.trim() || null,
          tds_status: form.tds_status || null,
          referred_by_name: form.referred_by_name.trim() || null,
          referred_by_phone: form.referred_by_phone.trim() || null,
        },
      })
      setEditing(false)
      toast.success(t("leads.detail.fieldsSaved"))
    } catch (e) {
      toast.error(e instanceof Error && e.message ? e.message : t("common.actionFailed"))
    }
  }

  async function onUploadChange(e: React.ChangeEvent<HTMLInputElement>) {
    const file = e.target.files?.[0]
    e.target.value = ""
    if (!file || !profile?.org_id) return
    const invalid = validateLeadDocument(file)
    if (invalid) {
      toast.error(t(`leads.document.error.${invalid}`))
      return
    }
    setUploading(true)
    try {
      await uploadLeadDocument(profile.org_id, lead.id, file)
      toast.success(t("leads.document.uploaded"))
    } catch {
      toast.error(t("common.actionFailed"))
    } finally {
      setUploading(false)
    }
  }

  async function openDocument() {
    if (!lead.report_storage_path) return
    const url = await leadDocumentSignedUrl(lead.report_storage_path)
    window.open(url, "_blank", "noreferrer")
  }

  return (
    <Card className="min-w-0 gap-3 px-5">
      <div className="flex items-center justify-between">
        <h2 className="text-sm font-semibold text-text">{t("leads.detail.leadFields")}</h2>
        {editing ? (
          <div className="flex gap-1.5">
            <Button size="sm" variant="ghost" onClick={() => setEditing(false)}>
              {t("common.cancel")}
            </Button>
            <Button size="sm" onClick={save} disabled={update.isPending || budgetInvalid}>
              {update.isPending ? <Loader2 className="size-3.5 animate-spin" /> : t("common.save")}
            </Button>
          </div>
        ) : (
          <Button size="sm" variant="outline" onClick={() => setEditing(true)}>
            {t("leads.detail.edit")}
          </Button>
        )}
      </div>

      {editing ? (
        <div className="space-y-2.5">
          <div className="space-y-1">
            <Label htmlFor="field-customer-requirement">{t("leads.new.customerRequirement")}</Label>
            <textarea
              id="field-customer-requirement"
              rows={2}
              value={form.customer_requirement}
              onChange={(e) => setForm((f) => ({ ...f, customer_requirement: e.target.value }))}
              className="w-full rounded-xl border border-border bg-surface px-3 py-2 text-sm text-text outline-none"
            />
          </div>
          <div className="space-y-1">
            <Label htmlFor="field-special-description">{t("leads.new.specialDescription")}</Label>
            <textarea
              id="field-special-description"
              rows={2}
              value={form.special_description}
              onChange={(e) => setForm((f) => ({ ...f, special_description: e.target.value }))}
              className="w-full rounded-xl border border-border bg-surface px-3 py-2 text-sm text-text outline-none"
            />
          </div>
          <div className="space-y-1">
            <Label htmlFor="field-budget">{t("leads.new.budget")}</Label>
            <Input id="field-budget" type="number" min={0} value={form.budget} onChange={(e) => setForm((f) => ({ ...f, budget: e.target.value }))} />
            {budgetInvalid ? <p className="text-xs text-danger">{t("leads.errors.budgetNonNegative")}</p> : null}
          </div>
          <div className="space-y-1">
            <Label htmlFor="field-when-needed">{t("leads.new.whenNeeded")}</Label>
            <Input id="field-when-needed" value={form.when_needed} onChange={(e) => setForm((f) => ({ ...f, when_needed: e.target.value }))} />
          </div>
          <div className="space-y-1">
            <Label htmlFor="field-tds">{t("leads.new.tds")}</Label>
            <Input id="field-tds" value={form.tds_status} onChange={(e) => setForm((f) => ({ ...f, tds_status: e.target.value }))} placeholder={t("leads.new.tdsPlaceholder")} />
          </div>
          <ReferredBySection
            orgId={profile?.org_id}
            source={lead.source}
            allowTechnicianOrStaff={false}
            referredByUserId=""
            onReferredByUserIdChange={() => {}}
            referredByName={form.referred_by_name}
            onReferredByNameChange={(next) => setForm((f) => ({ ...f, referred_by_name: next }))}
            referredByPhone={form.referred_by_phone}
            onReferredByPhoneChange={(next) => setForm((f) => ({ ...f, referred_by_phone: next }))}
          />
        </div>
      ) : (
        <div className="space-y-2 text-sm">
          <Field label={t("leads.new.customerRequirement")} value={lead.customer_requirement} />
          <Field label={t("leads.new.specialDescription")} value={lead.special_description} />
          <Field label={t("leads.new.budget")} value={lead.budget != null ? `₹${lead.budget}` : null} />
          <Field label={t("leads.new.whenNeeded")} value={lead.when_needed} />
          <Field label={t("leads.new.tds")} value={lead.tds_status} />
          <Field label={t("leads.new.referredByName")} value={lead.referred_by_name} />
          <Field label={t("leads.new.referredByPhone")} value={lead.referred_by_phone} />
        </div>
      )}

      <div className="flex items-center justify-between rounded-xl border border-dashed border-border px-3 py-2.5">
        <div className="flex items-center gap-2 text-xs text-text-muted">
          <Paperclip className="size-3.5" />
          {lead.report_storage_path ? (
            <button type="button" onClick={openDocument} className="font-medium text-accent hover:underline">
              {t("leads.document.view")}
            </button>
          ) : (
            t("leads.document.none")
          )}
        </div>
        <label className="inline-flex cursor-pointer items-center gap-1.5 rounded-full border border-border px-3 py-1.5 text-xs font-semibold text-text hover:bg-surface-alt">
          {uploading ? <Loader2 className="size-3.5 animate-spin" /> : t("leads.document.upload")}
          <input type="file" className="hidden" onChange={onUploadChange} disabled={uploading} accept=".pdf,.doc,.docx,.xls,.xlsx,.jpg,.jpeg,.png" />
        </label>
      </div>
    </Card>
  )
}

function Field({ label, value }: { label: string; value: string | null | undefined }) {
  return (
    <div>
      <p className="text-[11px] font-semibold uppercase tracking-wide text-text-muted">{label}</p>
      <p className="whitespace-pre-wrap text-text">{value || "—"}</p>
    </div>
  )
}
