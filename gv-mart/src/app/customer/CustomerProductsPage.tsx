import { useState } from "react"
import { useTranslation } from "react-i18next"
import { useNavigate } from "react-router-dom"
import { zodResolver } from "@hookform/resolvers/zod"
import { useForm } from "react-hook-form"
import { Loader2, Package, QrCode, ShieldCheck, Wrench } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { Card } from "@/components/ui/card"
import { StatusDot } from "@/components/shared/StatusDot"
import { FullPageError, FullPageLoader } from "@/components/shared/FullPageLoader"
import { useMyAmcContracts, useMyCustomerId, useMyWarranties, useOwnedProducts, useRegisterProductViaQr } from "@/hooks/useCustomerApp"
import { registerProductSchema, type RegisterProductInput } from "@/lib/validation/customerApp"

function RegisterProductForm({ orgId, customerId, onDone }: { orgId: string | undefined; customerId: string | undefined; onDone: () => void }) {
  const { t } = useTranslation()
  const { data: products } = useOwnedProducts(orgId)
  const registerProduct = useRegisterProductViaQr(orgId, customerId)

  const {
    register,
    handleSubmit,
    formState: { errors },
  } = useForm<RegisterProductInput>({ resolver: zodResolver(registerProductSchema), mode: "onChange" })

  const onSubmit = handleSubmit((values) => {
    registerProduct.mutate(
      { productId: values.productId, serialNo: values.serialNo ?? "", purchaseDate: values.purchaseDate || null },
      { onSuccess: () => onDone() }
    )
  })

  return (
    <Card className="gap-3">
      <div className="flex items-center gap-2 px-1">
        <QrCode className="size-4 text-text-muted" />
        <h2 className="text-sm font-semibold text-text">{t("customerApp.products.registerTitle")}</h2>
      </div>
      <p className="px-1 text-xs text-text-muted">{t("customerApp.products.registerHint")}</p>
      <form onSubmit={onSubmit} className="space-y-2.5 px-1">
        <div className="space-y-1">
          <Label>{t("customerApp.products.selectProduct")}</Label>
          <select
            className="h-10 w-full rounded-xl border border-border bg-surface px-3 text-sm text-text outline-none"
            aria-invalid={!!errors.productId}
            {...register("productId")}
          >
            <option value="">{t("customerApp.products.selectProductPlaceholder")}</option>
            {(products ?? []).map((p) => (
              <option key={p.id} value={p.id}>
                {[p.name, p.brands?.name, p.models?.name].filter(Boolean).join(" · ")}
              </option>
            ))}
          </select>
          {errors.productId ? <p className="text-xs text-danger">{t(errors.productId.message!)}</p> : null}
        </div>
        <div className="space-y-1">
          <Label>{t("customerApp.products.serialNo")}</Label>
          <Input placeholder={t("customerApp.products.serialNoPlaceholder")} {...register("serialNo")} />
        </div>
        <div className="space-y-1">
          <Label>{t("customerApp.products.purchaseDate")}</Label>
          <Input type="date" {...register("purchaseDate")} />
        </div>
        {registerProduct.isError ? <p className="text-xs text-danger">{(registerProduct.error as Error).message}</p> : null}
        <div className="flex justify-end gap-2 pt-1">
          <Button type="button" size="sm" variant="ghost" onClick={onDone}>
            {t("common.cancel")}
          </Button>
          <Button type="submit" size="sm" disabled={registerProduct.isPending}>
            {registerProduct.isPending ? <Loader2 className="size-3.5 animate-spin" /> : t("customerApp.products.register")}
          </Button>
        </div>
      </form>
    </Card>
  )
}

export function CustomerProductsPage() {
  const { t } = useTranslation()
  const navigate = useNavigate()
  const [showRegister, setShowRegister] = useState(false)
  const { customerId, orgId, isLoading: loadingId } = useMyCustomerId()
  const { data: warranties, isLoading: loadingW, isError: errorW, refetch: refetchW } = useMyWarranties(customerId)
  const { data: amcContracts, isLoading: loadingA, isError: errorA, refetch: refetchA } = useMyAmcContracts(customerId)

  const isLoading = loadingId || loadingW || loadingA
  const isError = errorW || errorA

  if (isLoading) return <FullPageLoader label={t("common.loading")} />
  if (isError) {
    return (
      <FullPageError
        message={t("customerApp.products.loadError")}
        onRetry={() => {
          refetchW()
          refetchA()
        }}
        retryLabel={t("common.retry")}
      />
    )
  }

  const today = new Date().toISOString().slice(0, 10)
  // AMC contracts and warranties can both reference the same product — key
  // cards by product_id so each owned product shows one card with whichever
  // coverage type it has (a product doesn't usually have both).
  const amcByProduct = new Map((amcContracts ?? []).map((c) => [c.product_id, c]))
  const warrantyByProduct = new Map((warranties ?? []).map((w) => [w.product_id, w]))
  const productIds = Array.from(new Set([...amcByProduct.keys(), ...warrantyByProduct.keys()]))

  return (
    <div className="space-y-4 pb-4 pt-2">
      <div className="flex items-center justify-between">
        <h1 className="text-xl font-bold text-text">{t("customerApp.products.title")}</h1>
        <Button size="sm" variant="outline" onClick={() => setShowRegister((v) => !v)}>
          <QrCode className="size-3.5" />
          {t("customerApp.products.registerViaQr")}
        </Button>
      </div>

      {showRegister ? <RegisterProductForm orgId={orgId} customerId={customerId} onDone={() => setShowRegister(false)} /> : null}

      {productIds.length === 0 ? (
        <Card className="items-center gap-1.5 py-8 text-center">
          <Package className="size-6 text-text-muted" />
          <p className="text-sm text-text-muted">{t("customerApp.products.empty")}</p>
          <Button size="sm" variant="outline" onClick={() => setShowRegister(true)}>
            {t("customerApp.products.registerViaQr")}
          </Button>
        </Card>
      ) : (
        <div className="space-y-3">
          {productIds.map((productId) => {
            const amc = amcByProduct.get(productId)
            const warranty = warrantyByProduct.get(productId)
            const p = (amc ?? warranty)?.products
            const name = p?.name ?? t("customerApp.products.unknownProduct")
            const brandModel = [p?.brands?.name, p?.models?.name].filter(Boolean).join(" · ")

            return (
              <Card key={productId} className="gap-2.5">
                <div className="flex items-start justify-between px-1">
                  <div>
                    <p className="text-sm font-semibold text-text">{name}</p>
                    {brandModel ? <p className="text-xs text-text-muted">{brandModel}</p> : null}
                  </div>
                  <span className="flex size-9 shrink-0 items-center justify-center rounded-full bg-accent-soft text-accent">
                    <Package className="size-4" />
                  </span>
                </div>

                {warranty ? (
                  <div className="space-y-1.5 rounded-xl border border-border px-3.5 py-2 text-xs">
                    <div className="flex items-center justify-between">
                      <StatusDot
                        tone={warranty.expiry_date >= today ? "info" : "neutral"}
                        label={warranty.expiry_date >= today ? t("customerApp.products.warrantyActive") : t("customerApp.products.warrantyExpired")}
                      />
                      <span className="text-text-muted">{t("customerApp.products.expiresOn", { date: warranty.expiry_date })}</span>
                    </div>
                    <p className="text-text-muted">{t("customerApp.products.purchasedOn", { date: warranty.start_date })}</p>
                  </div>
                ) : null}

                {amc ? (
                  <div className="space-y-1.5 rounded-xl border border-border px-3.5 py-2 text-xs">
                    <div className="flex items-center justify-between">
                      <StatusDot
                        tone={amc.status === "active" ? "success" : amc.status === "due_soon" ? "warning" : "danger"}
                        label={t(`customerApp.amc.status.${amc.status}`)}
                      />
                      <span className="flex items-center gap-1 text-text-muted">
                        <ShieldCheck className="size-3 shrink-0" />
                        {amc.amc_plans?.name}
                      </span>
                    </div>
                    <p className="text-text-muted">{t("customerApp.products.expiresOn", { date: amc.expiry_date })}</p>
                    {amc.next_service_date ? (
                      <p className="text-text-muted">{t("customerApp.products.nextServiceOn", { date: amc.next_service_date })}</p>
                    ) : null}
                  </div>
                ) : null}

                <Button size="sm" variant="outline" className="mx-1" onClick={() => navigate("/customer/book-service")}>
                  <Wrench className="size-3.5" />
                  {t("customerApp.products.bookService")}
                </Button>
              </Card>
            )
          })}
        </div>
      )}
    </div>
  )
}
