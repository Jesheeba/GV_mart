import { useEffect, useState } from "react"
import { useTranslation } from "react-i18next"
import { useNavigate } from "react-router-dom"
import { CheckCircle2, History, Loader2, PackageOpen, Printer } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Card } from "@/components/ui/card"
import { FullPageError, FullPageLoader } from "@/components/shared/FullPageLoader"
import { HandoverPrintSheet } from "@/components/shared/HandoverPrintSheet"
import { SignaturePad } from "./components/SignaturePad"
import { useToast } from "@/components/ui/toast-context"
import { useProfile } from "@/hooks/useProfile"
import { useOrganization } from "@/hooks/useSales"
import { useConfirmHandover, useMyTechnician, useTodayHandover } from "@/hooks/useTechnician"
import { spareHandoverSignSchema } from "@/lib/validation/technician"

export function SpareHandoverPage() {
  const { t } = useTranslation()
  const { toast } = useToast()
  const navigate = useNavigate()
  const { data: profile } = useProfile()
  const { data: org } = useOrganization(profile?.org_id)
  const technician = useMyTechnician()
  const handover = useTodayHandover(technician.data?.id)
  const confirmHandover = useConfirmHandover()
  const [techSign, setTechSign] = useState<string | null>(null)
  const [printing, setPrinting] = useState(false)

  useEffect(() => {
    if (!printing) return
    const id = setTimeout(() => window.print(), 50)
    return () => clearTimeout(id)
  }, [printing])

  if (technician.isLoading || handover.isLoading) return <FullPageLoader label={t("common.loading")} />
  if (technician.isError || !technician.data) {
    return <FullPageError message={t("technician.errors.loadFailed")} onRetry={() => technician.refetch()} retryLabel={t("common.retry")} />
  }
  if (handover.isError) {
    return <FullPageError message={t("technician.errors.loadFailed")} onRetry={() => handover.refetch()} retryLabel={t("common.retry")} />
  }

  const data = handover.data
  const items = data?.spare_handover_items ?? []
  const alreadyConfirmed = data?.status === "confirmed"
  const parsed = spareHandoverSignSchema.safeParse({ techSignDataUrl: techSign ?? "" })
  const canConfirm = !!data && !alreadyConfirmed && parsed.success

  async function handleConfirm() {
    if (!data || !techSign) return
    try {
      await confirmHandover.mutateAsync({ handoverId: data.id, techSignUrl: techSign, adminSignUrl: data.admin_sign_url ?? "" })
    } catch {
      toast.error(t("common.actionFailed"))
    }
  }

  return (
    <div className="space-y-4 pt-2">
      <div className="flex items-center justify-between gap-2 print:hidden">
        <h1 className="text-xl font-bold text-text">{t("technician.spareHandover.title")}</h1>
        <div className="flex items-center gap-1.5">
          {data ? (
            <Button type="button" size="icon-sm" variant="outline" title={t("technicians.spares.print")} onClick={() => setPrinting(true)}>
              <Printer className="size-4" />
            </Button>
          ) : null}
          <Button type="button" size="icon-sm" variant="outline" title={t("technician.spareHandover.history")} onClick={() => navigate("/technician/spares/history")}>
            <History className="size-4" />
          </Button>
        </div>
      </div>

      {!data ? (
        <Card className="items-center gap-2 py-8 text-center print:hidden">
          <PackageOpen className="size-8 text-text-muted" />
          <p className="text-sm font-medium text-text">{t("technician.spareHandover.emptyTitle")}</p>
          <p className="text-xs text-text-muted">{t("technician.spareHandover.emptyBody")}</p>
        </Card>
      ) : (
        <div className="space-y-4 print:hidden">
          <Card className="gap-3">
            <p className="px-1 text-sm font-semibold text-text">{t("technician.spareHandover.itemsTitle")}</p>
            {items.length === 0 ? (
              <p className="px-1 text-sm text-text-muted">{t("technician.spareHandover.noItems")}</p>
            ) : (
              <div className="divide-y divide-border">
                {items.map((item) => (
                  <div key={item.id} className="flex items-center justify-between px-1 py-2.5">
                    <div>
                      <p className="text-sm font-medium text-text">{item.spares?.name ?? "—"}</p>
                      <p className="text-xs text-text-muted">{item.spares?.sku ?? "—"}</p>
                    </div>
                    <span className="text-sm font-semibold text-text">{t("technician.spareHandover.qty", { qty: item.qty_given })}</span>
                  </div>
                ))}
              </div>
            )}
          </Card>

          <Card className="gap-3">
            <p className="px-1 text-sm font-semibold text-text">{t("technician.spareHandover.adminSignTitle")}</p>
            {data.admin_sign_url ? (
              <img src={data.admin_sign_url} alt={t("technician.spareHandover.adminSignTitle")} className="h-24 w-full rounded-xl border border-border bg-surface-alt object-contain" />
            ) : (
              <p className="px-1 text-sm text-text-muted">{t("technician.spareHandover.adminSignPending")}</p>
            )}
          </Card>

          {alreadyConfirmed ? (
            <Card className="items-center gap-2 text-center">
              <CheckCircle2 className="size-8 text-success" />
              <p className="text-sm font-semibold text-text">{t("technician.spareHandover.confirmedTitle")}</p>
            </Card>
          ) : (
            <Card className="gap-3">
              <p className="px-1 text-sm font-semibold text-text">{t("technician.spareHandover.techSignTitle")}</p>
              <SignaturePad onChange={setTechSign} disabled={confirmHandover.isPending} />
              <Button type="button" disabled={!canConfirm || confirmHandover.isPending} onClick={handleConfirm}>
                {confirmHandover.isPending ? <Loader2 className="size-4 animate-spin" /> : t("technician.spareHandover.confirmButton")}
              </Button>
              {!techSign ? <p className="px-1 text-xs text-text-muted">{t("technician.errors.signatureRequired")}</p> : null}
            </Card>
          )}
        </div>
      )}

      <Button type="button" variant="outline" className="print:hidden" onClick={() => navigate(-1)}>
        {t("common.back")}
      </Button>

      {printing && data ? (
        <HandoverPrintSheet
          orgName={org?.name ?? t("common.appName")}
          orgAddress={org?.address ?? null}
          orgPhone={org?.phone ?? null}
          technicianName={profile?.full_name ?? "—"}
          date={data.date}
          status={data.status}
          items={items.map((item) => ({
            id: item.id,
            name: item.spares?.name ?? "?",
            sku: item.spares?.sku ?? null,
            qty: item.qty_given,
          }))}
          adminSignUrl={data.admin_sign_url}
          techSignUrl={data.tech_sign_url}
        />
      ) : null}
    </div>
  )
}
