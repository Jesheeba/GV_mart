import { zodResolver } from "@hookform/resolvers/zod"
import { useForm } from "react-hook-form"
import { useTranslation } from "react-i18next"
import { Loader2 } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Card } from "@/components/ui/card"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { ReferrerPicker } from "@/components/shared/ReferrerPicker"
import { useToast } from "@/components/ui/toast-context"
import { useCreateLead } from "@/hooks/useAutomation"
import { leadSchema, type LeadInput } from "@/lib/validation/automation"
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
    defaultValues: { name: "", mobile: "", source: "other", productCategory: "", notes: "", kind: "", referredByUserId: "" },
  })

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
      </div>
      {createLead.error ? <p className="rounded-xl bg-danger/10 px-3.5 py-2.5 text-sm text-danger">{(createLead.error as Error).message}</p> : null}
      <div className="flex justify-end">
        <Button onClick={form.handleSubmit(onSubmit)} disabled={createLead.isPending}>
          {createLead.isPending ? <Loader2 className="size-4 animate-spin" /> : t("common.save")}
        </Button>
      </div>
    </Card>
  )
}
