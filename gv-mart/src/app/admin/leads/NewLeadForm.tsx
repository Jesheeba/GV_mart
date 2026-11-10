import { useState } from "react"
import { zodResolver } from "@hookform/resolvers/zod"
import { useForm } from "react-hook-form"
import { useTranslation } from "react-i18next"
import { Loader2 } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Card } from "@/components/ui/card"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { ReferrerPicker } from "@/components/shared/ReferrerPicker"
import { DuplicateContactWarning } from "@/components/shared/DuplicateContactWarning"
import { useToast } from "@/components/ui/toast-context"
import { useCreateLead } from "@/hooks/useAutomation"
import { useDuplicateContactWarning } from "@/hooks/useCustomers"
import { leadSchema, type LeadInput } from "@/lib/validation/automation"
import { canSubmitWithWarning, duplicateWarningKey } from "@/lib/duplicateContactWarning"
import { useProfile } from "@/hooks/useProfile"
import { useLeadSourceOptions } from "@/hooks/useLeadSources"
import { useLeadKindOptions, useLeadProductTypeOptions } from "@/hooks/useLeadLists"

export function NewLeadForm({ onClose, onCreated }: { onClose: () => void; onCreated: () => void }) {
  const { t } = useTranslation()
  const { toast } = useToast()
  const { data: profile } = useProfile()
  const createLead = useCreateLead()
  const { activeSources, label: sourceLabel } = useLeadSourceOptions()
  const { activeKinds, label: kindLabel } = useLeadKindOptions()
  const { activeProductTypes, label: productTypeLabel } = useLeadProductTypeOptions()

  const form = useForm<LeadInput>({
    resolver: zodResolver(leadSchema),
    mode: "onChange",
    defaultValues: {
      name: "",
      mobile: "",
      source: "other",
      productCategory: "",
      notes: "",
      kind: "",
      referredByUserId: "",
      customerRequirement: "",
      specialDescription: "",
      userSource: "",
      budget: "",
      whenNeeded: "",
      tdsStatus: "",
      referredByName: "",
      referredByPhone: "",
    },
  })

  // Urgent item (2026-11-02): same non-blocking staff-side duplicate-contact
  // warning as CustomerFormPage's Create Customer flow (DuplicateContactWarning
  // has the full rationale). Leads have no email field, so this is mobile-only.
  const leadMobile = form.watch("mobile") ?? ""
  const dupWarning = useDuplicateContactWarning(profile?.org_id, leadMobile)
  const dupWarningKey = duplicateWarningKey(leadMobile, "")
  const [confirmedDupWarningKey, setConfirmedDupWarningKey] = useState<string | null>(null)
  const dupWarningConfirmed = confirmedDupWarningKey === dupWarningKey

  async function onSubmit(values: LeadInput) {
    const referredByUserId = values.referredByUserId || null
    const created = await createLead.mutateAsync({
      org_id: profile!.org_id,
      name: values.name,
      mobile: values.mobile || null,
      source: values.source,
      product_type_key: values.productCategory || null,
      notes: values.notes || null,
      kind_key: values.kind || null,
      referred_by_user_id: referredByUserId,
      customer_requirement: values.customerRequirement || null,
      special_description: values.specialDescription || null,
      user_source: values.userSource || null,
      budget: values.budget ? Number(values.budget) : null,
      when_needed: values.whenNeeded || null,
      tds_status: values.tdsStatus || null,
      referred_by_name: values.referredByName || null,
      referred_by_phone: values.referredByPhone || null,
    })
    // Self-referral / anti-abuse guard (stage2_corrections_addendum.md item 9) —
    // a referral attempt can be silently nulled server-side rather than erroring,
    // so the save must never fail; this is just a non-blocking heads-up. Today
    // `createLead` is a plain `.insert()`, so the one signal available is the
    // returned row's own `referred_by_user_id` coming back null despite us
    // sending one. If/when the DB stream's RPC path starts returning an explicit
    // `referral_attributed: boolean` flag, prefer that over this inference.
    if (referredByUserId && (created as { referred_by_user_id?: string | null } | null)?.referred_by_user_id == null) {
      toast.warning(t("common.referralNotRecorded"))
    }
    onCreated()
  }

  return (
    <Card className="gap-3 px-5">
      <div className="flex items-center justify-between">
        <h2 className="text-sm font-semibold text-text">{t("leads.new.title")}</h2>
        <Button size="sm" variant="ghost" onClick={onClose}>
          {t("common.cancel")}
        </Button>
      </div>
      <div className="grid grid-cols-1 gap-3 sm:grid-cols-2">
        <div className="space-y-1.5">
          <Label htmlFor="lead-name">{t("leads.new.name")}</Label>
          <Input id="lead-name" {...form.register("name")} />
          {form.formState.errors.name ? <p className="text-xs text-danger">{t(form.formState.errors.name.message!)}</p> : null}
        </div>
        <div className="space-y-1.5">
          <Label htmlFor="lead-mobile">{t("leads.new.mobile")}</Label>
          <Input id="lead-mobile" {...form.register("mobile")} />
        </div>
        <div className="sm:col-span-2">
          <DuplicateContactWarning
            matches={dupWarning.data}
            isLoading={dupWarning.isFetching}
            confirmed={dupWarningConfirmed}
            onConfirmedChange={(next) => setConfirmedDupWarningKey(next ? dupWarningKey : null)}
          />
        </div>
        <div className="space-y-1.5">
          <Label htmlFor="lead-source">{t("leads.new.source")}</Label>
          <select id="lead-source" {...form.register("source")} className="h-10 w-full rounded-xl border border-border bg-surface px-3 text-sm text-text outline-none">
            {activeSources.map((s) => (
              <option key={s.key} value={s.key}>
                {sourceLabel(s.key)}
              </option>
            ))}
          </select>
        </div>
        <ReferrerPicker
          id="lead-referred-by"
          orgId={profile?.org_id}
          label={t("leads.new.referredBy")}
          value={form.watch("referredByUserId") ?? ""}
          onChange={(next) => form.setValue("referredByUserId", next)}
        />
        <div className="space-y-1.5">
          <Label htmlFor="lead-product-category">{t("leads.new.productCategory")}</Label>
          <select id="lead-product-category" {...form.register("productCategory")} className="h-10 w-full rounded-xl border border-border bg-surface px-3 text-sm text-text outline-none">
            <option value="">{t("service.filters.all")}</option>
            {activeProductTypes.map((p) => (
              <option key={p.key} value={p.key}>
                {productTypeLabel(p.key)}
              </option>
            ))}
          </select>
        </div>
        <div className="space-y-1.5">
          <Label htmlFor="lead-kind">{t("leads.new.kind")}</Label>
          <select id="lead-kind" {...form.register("kind")} className="h-10 w-full rounded-xl border border-border bg-surface px-3 text-sm text-text outline-none">
            <option value="">{t("service.filters.all")}</option>
            {activeKinds.map((k) => (
              <option key={k.key} value={k.key}>
                {kindLabel(k.key)}
              </option>
            ))}
          </select>
        </div>
        <div className="space-y-1.5 sm:col-span-2">
          <Label htmlFor="lead-notes">{t("leads.new.notes")}</Label>
          <textarea
            id="lead-notes"
            rows={4}
            placeholder={t("leads.new.notesPlaceholder")}
            {...form.register("notes")}
            className="w-full rounded-xl border border-border bg-surface px-3 py-2 text-sm text-text outline-none"
          />
        </div>
        <div className="space-y-1.5 sm:col-span-2">
          <Label htmlFor="lead-customer-requirement">{t("leads.new.customerRequirement")}</Label>
          <textarea
            id="lead-customer-requirement"
            rows={3}
            {...form.register("customerRequirement")}
            className="w-full rounded-xl border border-border bg-surface px-3 py-2 text-sm text-text outline-none"
          />
        </div>
        <div className="space-y-1.5 sm:col-span-2">
          <Label htmlFor="lead-special-description">{t("leads.new.specialDescription")}</Label>
          <textarea
            id="lead-special-description"
            rows={3}
            {...form.register("specialDescription")}
            className="w-full rounded-xl border border-border bg-surface px-3 py-2 text-sm text-text outline-none"
          />
        </div>
        <div className="space-y-1.5">
          <Label htmlFor="lead-user-source">{t("leads.new.userSource")}</Label>
          <Input id="lead-user-source" {...form.register("userSource")} placeholder={t("leads.new.userSourcePlaceholder")} />
        </div>
        <div className="space-y-1.5">
          <Label htmlFor="lead-budget">{t("leads.new.budget")}</Label>
          <Input id="lead-budget" type="number" min={0} {...form.register("budget")} />
          {form.formState.errors.budget ? <p className="text-xs text-danger">{t(form.formState.errors.budget.message!)}</p> : null}
        </div>
        <div className="space-y-1.5">
          <Label htmlFor="lead-when-needed">{t("leads.new.whenNeeded")}</Label>
          <Input id="lead-when-needed" {...form.register("whenNeeded")} placeholder={t("leads.new.whenNeededPlaceholder")} />
        </div>
        <div className="space-y-1.5">
          <Label htmlFor="lead-tds">{t("leads.new.tds")}</Label>
          <select id="lead-tds" {...form.register("tdsStatus")} className="h-10 w-full rounded-xl border border-border bg-surface px-3 text-sm text-text outline-none">
            <option value="">{t("leads.tds.select")}</option>
            <option value="applicable">{t("leads.tds.applicable")}</option>
            <option value="not_applicable">{t("leads.tds.notApplicable")}</option>
            <option value="to_be_confirmed">{t("leads.tds.toBeConfirmed")}</option>
          </select>
        </div>
        <div className="space-y-1.5 sm:col-span-2 sm:grid sm:grid-cols-2 sm:gap-3">
          <div className="space-y-1.5">
            <Label htmlFor="lead-referred-name">{t("leads.new.referredByName")}</Label>
            <Input id="lead-referred-name" {...form.register("referredByName")} />
          </div>
          <div className="space-y-1.5">
            <Label htmlFor="lead-referred-phone">{t("leads.new.referredByPhone")}</Label>
            <Input id="lead-referred-phone" type="tel" {...form.register("referredByPhone")} />
          </div>
        </div>
      </div>
      {createLead.error ? <p className="rounded-xl bg-danger/10 px-3.5 py-2.5 text-sm text-danger">{(createLead.error as Error).message}</p> : null}
      <div className="flex justify-end">
        <Button
          onClick={form.handleSubmit(onSubmit)}
          disabled={createLead.isPending || !canSubmitWithWarning(dupWarning.data, dupWarningConfirmed)}
        >
          {createLead.isPending ? <Loader2 className="size-4 animate-spin" /> : t("common.save")}
        </Button>
      </div>
    </Card>
  )
}
