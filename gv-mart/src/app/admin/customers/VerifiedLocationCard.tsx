import { useState } from "react"
import { useTranslation } from "react-i18next"
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import { Loader2, ShieldCheck } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { getTechnicianName, resetVerifiedLocation } from "@/services/customers"

/**
 * Replaces the editable map for an address whose pin a technician verified on site
 * (arrival location lock, 20261214100000). The pin can't be moved here; only a master
 * can lift the lock, with a reason, and the next technician arrival re-verifies it.
 */
export function VerifiedLocationCard({
  customerId,
  addressId,
  lat,
  lng,
  verifiedAt,
  verifiedBy,
  canReset,
}: {
  customerId: string
  addressId: string
  lat: number
  lng: number
  verifiedAt: string
  verifiedBy: string | null
  canReset: boolean
}) {
  const { t, i18n } = useTranslation()
  const queryClient = useQueryClient()
  const [resetting, setResetting] = useState(false)
  const [reason, setReason] = useState("")

  const technicianName = useQuery({
    queryKey: ["technicians", "name", verifiedBy],
    queryFn: () => getTechnicianName(verifiedBy!),
    enabled: !!verifiedBy,
  })
  const reset = useMutation({
    mutationFn: () => resetVerifiedLocation(addressId, reason.trim()),
    onSuccess: () => queryClient.invalidateQueries({ queryKey: ["customers", "detail", customerId] }),
  })

  const date = new Date(verifiedAt).toLocaleDateString(i18n.language === "ta" ? "ta-IN" : "en-IN", { day: "numeric", month: "short", year: "numeric" })

  return (
    <div className="space-y-2 rounded-xl border border-success/30 bg-success/10 px-3 py-2.5">
      <p className="flex items-center gap-1.5 text-sm font-medium text-success">
        <ShieldCheck className="size-4 shrink-0" />
        {t("customers.form.map.verifiedOnSite", { name: technicianName.data ?? t("customers.form.map.verifiedTechnicianFallback"), date })}
      </p>
      <p className="text-xs text-text-muted">
        {t("customers.form.map.verifiedLockedNote")}{" "}
        <a
          href={`https://www.google.com/maps/search/?api=1&query=${lat},${lng}`}
          target="_blank"
          rel="noopener noreferrer"
          className="font-medium text-text underline"
        >
          {t("customers.form.map.verifiedOpenInMaps")}
        </a>
      </p>
      {canReset ? (
        resetting ? (
          <div className="space-y-1.5 border-t border-success/20 pt-2">
            <Label htmlFor="reset-location-reason">{t("customers.form.map.resetReasonLabel")}</Label>
            <Input id="reset-location-reason" value={reason} onChange={(e) => setReason(e.target.value)} placeholder={t("customers.form.map.resetReasonPlaceholder")} />
            {reset.isError ? <p className="text-xs text-danger">{(reset.error as Error).message}</p> : null}
            <div className="flex gap-2">
              <Button type="button" size="sm" variant="outline" onClick={() => setResetting(false)} disabled={reset.isPending}>
                {t("common.cancel")}
              </Button>
              <Button type="button" size="sm" onClick={() => reset.mutate()} disabled={reset.isPending || reason.trim().length < 3}>
                {reset.isPending ? <Loader2 className="size-3.5 animate-spin" /> : t("customers.form.map.resetConfirm")}
              </Button>
            </div>
          </div>
        ) : (
          <Button type="button" size="sm" variant="outline" onClick={() => setResetting(true)}>
            {t("customers.form.map.resetVerified")}
          </Button>
        )
      ) : null}
    </div>
  )
}
