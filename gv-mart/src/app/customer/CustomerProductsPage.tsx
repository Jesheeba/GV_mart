import { useState } from "react"
import { useTranslation } from "react-i18next"
import { useNavigate } from "react-router-dom"
import { zodResolver } from "@hookform/resolvers/zod"
import { useForm } from "react-hook-form"
import { Loader2, Package, QrCode, Wrench } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { Card } from "@/components/ui/card"
import { FullPageError, FullPageLoader } from "@/components/shared/FullPageLoader"
import { OwnedProductStatusCard } from "@/app/customer/components/OwnedProductStatusCard"
import { useMyCustomerId, useOwnedProducts, useOwnedProductsWithStatus, useRegisterProductViaQr } from "@/hooks/useCustomerApp"
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
  const { data: rows, isLoading: loadingRows, isError, refetch } = useOwnedProductsWithStatus(customerId)

  const isLoading = loadingId || loadingRows

  if (isLoading) return <FullPageLoader label={t("common.loading")} />
  if (isError) {
    return <FullPageError message={t("customerApp.products.loadError")} onRetry={() => refetch()} retryLabel={t("common.retry")} />
  }

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

      {(rows ?? []).length === 0 ? (
        <Card className="items-center gap-1.5 py-8 text-center">
          <Package className="size-6 text-text-muted" />
          <p className="text-sm text-text-muted">{t("customerApp.products.empty")}</p>
          <Button size="sm" variant="outline" onClick={() => setShowRegister(true)}>
            {t("customerApp.products.registerViaQr")}
          </Button>
        </Card>
      ) : (
        <div className="space-y-3">
          {(rows ?? []).map(({ product, amc, warranty }) => (
            <OwnedProductStatusCard
              key={product.id}
              product={product}
              amc={amc}
              warranty={warranty}
              showAmcSection={product.category === "ro"}
              actionSlot={
                <Button size="sm" variant="outline" className="mx-1" onClick={() => navigate("/customer/book-service")}>
                  <Wrench className="size-3.5" />
                  {t("customerApp.products.bookService")}
                </Button>
              }
            />
          ))}
        </div>
      )}
    </div>
  )
}
