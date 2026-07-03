import { useState } from "react"
import { useTranslation } from "react-i18next"
import { useNavigate } from "react-router-dom"
import { CheckCircle2, Loader2, PackageOpen } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Card } from "@/components/ui/card"
import { FullPageError, FullPageLoader } from "@/components/shared/FullPageLoader"
import { SignaturePad } from "./components/SignaturePad"
import { useConfirmHandover, useMyTechnician, useTodayHandover } from "@/hooks/useTechnician"
import { spareHandoverSignSchema } from "@/lib/validation/technician"

export function SpareHandoverPage() {
  const { t } = useTranslation()
  const navigate = useNavigate()
  const technician = useMyTechnician()
  const handover = useTodayHandover(technician.data?.id)
  const confirmHandover = useConfirmHandover()
  const [techSign, setTechSign] = useState<string | null>(null)

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
    await confirmHandover.mutateAsync({ handoverId: data.id, techSignUrl: techSign, adminSignUrl: data.admin_sign_url ?? "" })
  }

  return (
    <div className="space-y-4 pt-2">
      <h1 className="text-xl font-bold text-text">{t("technician.spareHandover.title")}</h1>

      {!data ? (
        <Card className="items-center gap-2 py-8 text-center">
          <PackageOpen className="size-8 text-text-muted" />
          <p className="text-sm font-medium text-text">{t("technician.spareHandover.emptyTitle")}</p>
          <p className="text-xs text-text-muted">{t("technician.spareHandover.emptyBody")}</p>
        </Card>
      ) : (
        <>
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
        </>
      )}

      <Button type="button" variant="outline" onClick={() => navigate(-1)}>
        {t("common.back")}
      </Button>
    </div>
  )
}
