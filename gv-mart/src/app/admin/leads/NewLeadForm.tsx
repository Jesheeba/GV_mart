import { zodResolver } from "@hookform/resolvers/zod"
import { useForm } from "react-hook-form"
import { useTranslation } from "react-i18next"
import { Loader2 } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Card } from "@/components/ui/card"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { useCreateLead } from "@/hooks/useAutomation"
import { leadSchema, type LeadInput } from "@/lib/validation/automation"
import { useProfile } from "@/hooks/useProfile"
import type { Enums } from "@/types/database"

const SOURCES = ["field", "customer_app", "whatsapp", "walk_in", "referral", "other"] as const
const ENQUIRY_TYPES = ["online", "price", "quality", "customization", "water_premium", "budget"] as const
const KINDS = ["service", "spare", "product", "amc"] as const

export function NewLeadForm({ onClose, onCreated }: { onClose: () => void; onCreated: () => void }) {
  const { t } = useTranslation()
  const { data: profile } = useProfile()
  const createLead = useCreateLead()

  const form = useForm<LeadInput>({
    resolver: zodResolver(leadSchema),
    mode: "onChange",
    defaultValues: { name: "", mobile: "", source: "other", enquiryType: "", kind: "" },
  })

  async function onSubmit(values: LeadInput) {
    await createLead.mutateAsync({
      org_id: profile!.org_id,
      name: values.name,
      mobile: values.mobile || null,
      source: values.source,
      enquiry_type: (values.enquiryType || null) as Enums<"enquiry_type"> | null,
      kind: (values.kind || null) as Enums<"lead_kind"> | null,
    })
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
          <Label>{t("leads.new.name")}</Label>
          <Input {...form.register("name")} />
          {form.formState.errors.name ? <p className="text-xs text-danger">{t(form.formState.errors.name.message!)}</p> : null}
        </div>
        <div className="space-y-1.5">
          <Label>{t("leads.new.mobile")}</Label>
          <Input {...form.register("mobile")} />
        </div>
        <div className="space-y-1.5">
          <Label>{t("leads.new.source")}</Label>
          <select {...form.register("source")} className="h-10 w-full rounded-xl border border-border bg-surface px-3 text-sm text-text outline-none">
            {SOURCES.map((s) => (
              <option key={s} value={s}>
                {t(`leads.source.${s}`)}
              </option>
            ))}
          </select>
        </div>
        <div className="space-y-1.5">
          <Label>{t("leads.new.enquiryType")}</Label>
          <select {...form.register("enquiryType")} className="h-10 w-full rounded-xl border border-border bg-surface px-3 text-sm text-text outline-none">
            <option value="">{t("service.filters.all")}</option>
            {ENQUIRY_TYPES.map((e) => (
              <option key={e} value={e}>
                {t(`leads.enquiryType.${e}`)}
              </option>
            ))}
          </select>
        </div>
        <div className="space-y-1.5">
          <Label>{t("leads.new.kind")}</Label>
          <select {...form.register("kind")} className="h-10 w-full rounded-xl border border-border bg-surface px-3 text-sm text-text outline-none">
            <option value="">{t("service.filters.all")}</option>
            {KINDS.map((k) => (
              <option key={k} value={k}>
                {t(`leads.kind.${k}`)}
              </option>
            ))}
          </select>
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
