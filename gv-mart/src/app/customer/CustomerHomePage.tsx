import { useTranslation } from "react-i18next"
import { useNavigate } from "react-router-dom"
import { Bell, ChevronRight, MapPin, ShieldCheck, Sparkles, Wrench } from "lucide-react"
import { Card } from "@/components/ui/card"
import { Button } from "@/components/ui/button"
import { StatusDot } from "@/components/shared/StatusDot"
import { FullPageError, FullPageLoader } from "@/components/shared/FullPageLoader"
import { useProfile } from "@/hooks/useProfile"
import { useMyAddresses, useMyAmcContracts, useMyCustomerId, useMyWarranties } from "@/hooks/useCustomerApp"

function AddressBar() {
  const { t } = useTranslation()
  const navigate = useNavigate()
  const { customerId } = useMyCustomerId()
  const { data: addresses, isLoading } = useMyAddresses(customerId)
  const primary = addresses?.find((a) => a.is_primary) ?? addresses?.[0]

  const fullAddress = primary
    ? [primary.door_no, primary.street_cross, primary.area, primary.pincode].filter(Boolean).join(", ")
    : ""

  return (
    <div className="flex w-full items-center gap-2 rounded-lg border border-border bg-surface px-3 py-1.5">
      <span className="flex size-6 shrink-0 items-center justify-center rounded-full bg-accent-soft text-accent">
        <MapPin className="size-3.5" />
      </span>
      <div className="min-w-0 flex-1">
        <p className="text-[11px] leading-tight text-text-muted">{t("customerApp.home.deliverTo")}</p>
        {isLoading ? (
          <p className="text-xs text-text-muted">{t("common.loading")}</p>
        ) : primary ? (
          <p className="whitespace-normal break-words text-xs font-medium text-text">{fullAddress}</p>
        ) : (
          <p className="text-xs font-medium text-warning">{t("customerApp.home.noAddressYet")}</p>
        )}
      </div>
      <button
        type="button"
        onClick={() => navigate("/customer/profile")}
        aria-label={t("customerApp.bookService.changeAddressInProfile")}
        className="shrink-0 rounded-full p-1 text-text-muted hover:bg-surface-alt/60"
      >
        <ChevronRight className="size-4" />
      </button>
    </div>
  )
}

function ActionTile({ icon: Icon, label, onClick }: { icon: typeof Wrench; label: string; onClick: () => void }) {
  return (
    <button
      type="button"
      onClick={onClick}
      className="flex flex-col items-center gap-2 rounded-xl border border-border bg-surface px-2 py-4 text-center transition-colors hover:bg-surface-alt/60"
    >
      <span className="flex size-11 items-center justify-center rounded-full bg-ink text-white">
        <Icon className="size-5" />
      </span>
      <span className="text-xs font-medium text-text">{label}</span>
    </button>
  )
}

function NextServiceBanner() {
  const { t } = useTranslation()
  const navigate = useNavigate()
  const { customerId } = useMyCustomerId()
  const { data: amcContracts } = useMyAmcContracts(customerId)

  const next = (amcContracts ?? [])
    .filter((c) => c.next_service_date)
    .sort((a, b) => (a.next_service_date! < b.next_service_date! ? -1 : 1))[0]

  if (!next) return null

  const dueDate = new Date(next.next_service_date!)
  const daysUntil = Math.ceil((dueDate.getTime() - Date.now()) / (1000 * 60 * 60 * 24))

  return (
    <button
      type="button"
      onClick={() => navigate("/customer/amc")}
      className="flex w-full items-center gap-3 rounded-xl bg-gradient-to-br from-accent to-[#FF7A45] px-3.5 py-3 text-left text-white"
    >
      <Sparkles className="size-5 shrink-0" />
      <div className="min-w-0 flex-1">
        <p className="text-sm font-semibold">{t("customerApp.home.nextServiceDue")}</p>
        <p className="text-xs text-white/85">
          {daysUntil <= 0
            ? t("customerApp.home.nextServiceOverdue", { date: dueDate.toLocaleDateString() })
            : t("customerApp.home.nextServiceInDays", { count: daysUntil, date: dueDate.toLocaleDateString() })}
        </p>
      </div>
      <ChevronRight className="size-4 shrink-0" />
    </button>
  )
}

function StatusCards() {
  const { t } = useTranslation()
  const navigate = useNavigate()
  const { customerId } = useMyCustomerId()
  const { data: warranties, isLoading: loadingWarranties } = useMyWarranties(customerId)
  const { data: amcContracts, isLoading: loadingAmc } = useMyAmcContracts(customerId)

  const isLoading = loadingWarranties || loadingAmc
  const hasAny = (warranties?.length ?? 0) > 0 || (amcContracts?.length ?? 0) > 0

  if (isLoading) {
    return (
      <div className="grid grid-cols-2 gap-3">
        <div className="h-24 animate-pulse rounded-xl bg-surface-alt" />
        <div className="h-24 animate-pulse rounded-xl bg-surface-alt" />
      </div>
    )
  }

  if (!hasAny) {
    return (
      <Card className="items-center gap-1.5 py-6 text-center lg:px-5">
        <ShieldCheck className="size-6 text-text-muted" />
        <p className="text-sm text-text-muted">{t("customerApp.home.noProductsYet")}</p>
        <Button size="sm" variant="outline" onClick={() => navigate("/customer/products")}>
          {t("customerApp.home.viewMyProducts")}
        </Button>
      </Card>
    )
  }

  return (
    <div className="grid grid-cols-2 gap-3">
      {amcContracts?.slice(0, 2).map((c) => {
        const today = new Date().toISOString().slice(0, 10)
        const tone = c.status === "active" ? "success" : c.status === "due_soon" ? "warning" : "danger"
        return (
          <Card key={c.id} size="sm" className="gap-1.5 lg:px-5" onClick={() => navigate("/customer/amc")}>
            <p className="px-1 text-xs font-medium text-text-muted">{(c as { products?: { name?: string } }).products?.name ?? t("customerApp.home.amcCoverage")}</p>
            <StatusDot tone={tone} label={t(`customerApp.amc.status.${c.status}`)} className="px-1" />
            <p className="px-1 text-xs text-text-muted">
              {c.expiry_date >= today ? t("customerApp.home.expiresOn", { date: c.expiry_date }) : t("customerApp.home.expiredOn", { date: c.expiry_date })}
            </p>
          </Card>
        )
      })}
      {warranties?.slice(0, 2 - Math.min(2, amcContracts?.length ?? 0)).map((w) => {
        const today = new Date().toISOString().slice(0, 10)
        const active = w.expiry_date >= today
        return (
          <Card key={w.id} size="sm" className="gap-1.5 lg:px-5" onClick={() => navigate("/customer/products")}>
            <p className="px-1 text-xs font-medium text-text-muted">{(w as { products?: { name?: string } }).products?.name ?? t("customerApp.home.warrantyCoverage")}</p>
            <StatusDot tone={active ? "info" : "neutral"} label={active ? t("customerApp.home.warrantyActive") : t("customerApp.home.warrantyExpired")} className="px-1" />
            <p className="px-1 text-xs text-text-muted">{t("customerApp.home.expiresOn", { date: w.expiry_date })}</p>
          </Card>
        )
      })}
    </div>
  )
}

export function CustomerHomePage() {
  const { t } = useTranslation()
  const navigate = useNavigate()
  const { data: profile, isLoading, isError, refetch } = useProfile()

  if (isLoading) return <FullPageLoader label={t("common.loading")} />
  if (isError || !profile) {
    return <FullPageError message={t("auth.profileLoadError")} onRetry={() => refetch()} retryLabel={t("common.retry")} />
  }

  return (
    <div className="space-y-4 pb-4 pt-2">
      <div className="flex items-start justify-between">
        <h1 className="text-xl font-bold text-text">{t("dashboard.welcomeBack", { name: profile.full_name.split(" ")[0] })}</h1>
        <button
          type="button"
          onClick={() => navigate("/customer/notifications")}
          className="flex size-9 items-center justify-center rounded-full bg-surface-alt text-text-muted hover:text-text"
          title={t("shell.notifications")}
        >
          <Bell className="size-4" />
        </button>
      </div>

      <AddressBar />

      <NextServiceBanner />

      <div>
        <h2 className="mb-2 px-1 text-sm font-semibold text-text">{t("customerApp.home.quickActions")}</h2>
        <div className="grid grid-cols-4 gap-2">
          <ActionTile icon={Wrench} label={t("customerApp.home.tileService")} onClick={() => navigate("/customer/book-service")} />
          <ActionTile icon={Sparkles} label={t("customerApp.home.tileSpare")} onClick={() => navigate("/customer/spare-enquiry")} />
          <ActionTile icon={ShieldCheck} label={t("customerApp.home.tileProduct")} onClick={() => navigate("/customer/product-enquiry")} />
          <ActionTile icon={Bell} label={t("customerApp.home.tileAmc")} onClick={() => navigate("/customer/amc")} />
        </div>
      </div>

      <div>
        <div className="mb-2 flex items-center justify-between px-1">
          <h2 className="text-sm font-semibold text-text">{t("customerApp.home.coverageStatus")}</h2>
          <button type="button" className="text-xs font-medium text-accent" onClick={() => navigate("/customer/products")}>
            {t("customerApp.home.viewAll")}
          </button>
        </div>
        <StatusCards />
      </div>
    </div>
  )
}
