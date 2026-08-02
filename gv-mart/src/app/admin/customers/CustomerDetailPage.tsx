import { useTranslation } from "react-i18next"
import { useNavigate, useParams } from "react-router-dom"
import { BatteryCharging, ChevronLeft, Droplet, MapPin, MessageCircle, Package, Pencil, Phone, ReceiptText, Wind, Wrench, Zap } from "lucide-react"
import { Card } from "@/components/ui/card"
import { Button } from "@/components/ui/button"
import { Skeleton } from "@/components/ui/skeleton"
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs"
import { StatusDot, type StatusTone } from "@/components/shared/StatusDot"
import { FullPageError, FullPageLoader } from "@/components/shared/FullPageLoader"
import {
  useCustomer,
  useCustomerExemptionWindows,
  useCustomerInvoices,
  useCustomerLifetimeSummary,
  useCustomerProducts,
  useCustomerTimeline,
} from "@/hooks/useCustomers"
import { useProfile } from "@/hooks/useProfile"
import { avatarPalette, initials } from "@/lib/avatar"
import { formatCurrency } from "@/lib/sale-calc"
import { cn } from "@/lib/utils"
import type { Enums } from "@/types/database"
import { ExemptionWindowsPanel } from "./ExemptionWindowsPanel"
import { FamilyMembersPanel } from "./FamilyMembersPanel"

const AMC_STATUS_TONE: Record<string, StatusTone> = { active: "success", due_soon: "warning", expired: "danger" }

const CATEGORY_STYLE: Record<Enums<"brand_category">, { icon: typeof Droplet; bg: string; fg: string }> = {
  ro: { icon: Droplet, bg: "#E6EEFC", fg: "#2E6BE6" },
  ac: { icon: Wind, bg: "#FDE7DD", fg: "#F5612C" },
  inverter: { icon: BatteryCharging, bg: "#F0EBE3", fg: "#1A1A1A" },
  battery: { icon: BatteryCharging, bg: "#E2F3EA", fg: "#16855B" },
}

function fmtDate(iso: string | null | undefined, opts?: Intl.DateTimeFormatOptions) {
  if (!iso) return "—"
  return new Date(iso).toLocaleDateString("en-IN", opts ?? { day: "2-digit", month: "short", year: "numeric" })
}

function EmptyTab({ icon: Icon, label }: { icon: typeof Package; label: string }) {
  return (
    <div className="flex flex-col items-center gap-2 py-10 text-center">
      <span className="flex size-10 items-center justify-center rounded-full bg-surface-alt text-text-muted">
        <Icon className="size-5" />
      </span>
      <p className="text-sm text-text-muted">{label}</p>
    </div>
  )
}

function ProductCard({
  icon: Icon,
  iconBg,
  iconFg,
  title,
  subtitle,
  coverage,
}: {
  icon: typeof Package
  iconBg: string
  iconFg: string
  title: string
  subtitle: string
  coverage: { tone: StatusTone; label: string } | { plain: string }
}) {
  return (
    <div className="flex items-center gap-3.5 rounded-[18px] border border-border bg-surface p-4.5 shadow-[0_1px_2px_rgba(26,26,26,.04)]">
      <span className="flex size-11 shrink-0 items-center justify-center rounded-[13px]" style={{ background: iconBg, color: iconFg }}>
        <Icon className="size-5.5" strokeWidth={1.6} />
      </span>
      <div className="min-w-0 flex-1">
        <div className="truncate text-sm font-bold text-text">{title}</div>
        <div className="truncate text-xs font-medium text-text-muted">{subtitle}</div>
      </div>
      {"tone" in coverage ? (
        <StatusDot tone={coverage.tone} label={coverage.label} className="shrink-0" />
      ) : (
        <span className="shrink-0 text-xs font-medium text-text-muted">{coverage.plain}</span>
      )}
    </div>
  )
}

export function CustomerDetailPage() {
  const { t } = useTranslation()
  const navigate = useNavigate()
  const { id } = useParams<{ id: string }>()
  const { data: profile } = useProfile()
  const orgId = profile?.org_id
  const { data: customer, isLoading, isError, refetch } = useCustomer(id)

  const products = useCustomerProducts(orgId, customer?.id)
  const timeline = useCustomerTimeline(orgId, customer?.id)
  const invoices = useCustomerInvoices(orgId, customer?.id)
  const lifetime = useCustomerLifetimeSummary(orgId, customer?.id)
  const exemptionWindows = useCustomerExemptionWindows(customer?.id)

  if (isLoading) return <FullPageLoader label={t("common.loading")} />
  if (isError || !customer) {
    return <FullPageError message={t("customers.error.loadFailed")} onRetry={() => refetch()} retryLabel={t("common.retry")} />
  }

  const primaryAddress = customer.addresses.find((a) => a.is_primary) ?? customer.addresses[0]
  const waNumber = customer.mobile.replace(/\D/g, "")
  const palette = avatarPalette(customer.name)
  const subtitleParts = [
    customer.profession || null,
    t("customers.detail.customerSince", { date: fmtDate(customer.created_at, { month: "short", year: "numeric" }) }),
  ].filter(Boolean)

  const nextAmcAction = lifetime.data?.nextAmcAction ?? null
  const nextActionLabel = lifetime.isLoading
    ? "—"
    : nextAmcAction
      ? nextAmcAction.daysUntil <= 0
        ? t("customers.detail.amcRenewsToday")
        : t("customers.detail.amcRenewsIn", { days: nextAmcAction.daysUntil })
      : t("customers.detail.noUpcomingRenewals")

  // Products and Service History are separate tabs (see TabsList below) and
  // must render distinct content — they previously both called the same
  // combined renderer, which made switching tabs a visual no-op.
  function renderProducts() {
    return (
      <div className="flex flex-col gap-3.5">
        {products.isLoading ? (
          <>
            <Skeleton className="h-19 w-full rounded-[18px]" />
            <Skeleton className="h-19 w-full rounded-[18px]" />
          </>
        ) : (products.data ?? []).length === 0 ? (
          <div className="rounded-[18px] border border-border bg-surface">
            <EmptyTab icon={Package} label={t("customers.detail.emptyTabs.products")} />
          </div>
        ) : (
          (products.data ?? []).map((p) => {
            const style = p.category ? CATEGORY_STYLE[p.category] : null
            const Icon = style?.icon ?? Package
            const title = [p.brandName, p.modelName].filter(Boolean).join(" · ") || p.productName
            const subtitle =
              [
                p.boughtAt ? t("customers.detail.productCard.bought", { date: fmtDate(p.boughtAt, { month: "short", year: "numeric" }) }) : null,
                p.serialNo ? t("customers.detail.productCard.serial", { serial: p.serialNo }) : null,
              ]
                .filter(Boolean)
                .join(" · ") || "—"
            const coverage: { tone: StatusTone; label: string } | { plain: string } = p.amcStatus
              ? { tone: AMC_STATUS_TONE[p.amcStatus] ?? "neutral", label: `${p.amcPlanName ?? "—"} · ${t(`amc.status.${p.amcStatus}`)}` }
              : p.warrantyExpiry
                ? new Date(p.warrantyExpiry) >= new Date()
                  ? { tone: "success", label: t("customers.detail.productCard.warrantyTo", { date: fmtDate(p.warrantyExpiry) }) }
                  : { tone: "danger", label: t("customers.detail.productCard.warrantyExpired") }
                : { plain: t("customers.detail.productCard.noCoverage") }
            return <ProductCard key={p.productId} icon={Icon} iconBg={style?.bg ?? "#F0EBE3"} iconFg={style?.fg ?? "#1A1A1A"} title={title} subtitle={subtitle} coverage={coverage} />
          })
        )}
      </div>
    )
  }

  function renderServiceHistory() {
    return (
      <div className="rounded-card border border-border bg-surface p-5.5 shadow-[0_1px_2px_rgba(26,26,26,.04),0_14px_30px_-22px_rgba(26,26,26,.16)]">
        <h3 className="mb-4.5 text-base font-bold tracking-tight text-text">{t("customers.detail.serviceHistoryTitle")}</h3>
        {timeline.isLoading ? (
          <Skeleton className="h-24 w-full" />
        ) : (timeline.data ?? []).length === 0 ? (
          <EmptyTab icon={Wrench} label={t("customers.detail.emptyTabs.service")} />
        ) : (
          <div className="flex flex-col">
            {(timeline.data ?? []).map((entry, i, arr) => {
              // Dot is "lit" (success) for a completed ticket, an active AMC
              // contract, or any invoice (invoices are always a completed event).
              const dotOn = entry.kind === "ticket" ? entry.status === "completed" : entry.kind === "amc" ? entry.status === "active" : true
              let title: string
              let metaParts: (string | null | false)[]
              if (entry.kind === "ticket") {
                title = entry.title
                metaParts = [
                  entry.technicianName,
                  fmtDate(entry.date),
                  entry.ticketType ? t(`service.type.${entry.ticketType}`) : t(`service.status.${entry.status}`),
                  formatCurrency(entry.amount),
                ]
              } else if (entry.kind === "amc") {
                title = t(entry.isRenewal ? "customers.detail.timeline.amcRenewed" : "customers.detail.timeline.amcSold", {
                  defaultValue: entry.isRenewal ? "AMC renewed — {{plan}}" : "AMC sold — {{plan}}",
                  plan: entry.planName,
                })
                metaParts = [entry.productName, fmtDate(entry.date), t(`amc.status.${entry.status}`), formatCurrency(entry.amount)]
              } else {
                title = t("customers.detail.timeline.invoiceTitle", {
                  defaultValue: "{{type}} invoice",
                  type: t(`invoiceType.${entry.invoiceType}`),
                })
                metaParts = [entry.itemsLabel, fmtDate(entry.date), formatCurrency(entry.amount)]
              }
              return (
                <div key={`${entry.kind}-${entry.id}`} className="flex gap-3.25">
                  <div className="flex flex-col items-center">
                    <span className={cn("size-2.75 shrink-0 rounded-full", dotOn ? "border-2.5 border-success/20 bg-success" : "bg-border")} />
                    {i < arr.length - 1 ? <span className="w-0.5 flex-1 bg-border" /> : null}
                  </div>
                  <div className={cn("min-w-0", i < arr.length - 1 && "pb-4.5")}>
                    <div className="text-sm font-semibold text-text">{title}</div>
                    <div className="text-[11px] font-medium text-text-muted">{metaParts.filter(Boolean).join(" · ")}</div>
                  </div>
                </div>
              )
            })}
          </div>
        )}
      </div>
    )
  }

  return (
    <div className="space-y-4 pt-2">
      <div className="flex items-center gap-2 text-sm">
        <button
          type="button"
          onClick={() => navigate("/admin/customers")}
          title={t("customers.detail.backToList")}
          className="flex items-center gap-1 font-semibold text-text-muted hover:text-text"
        >
          <ChevronLeft className="size-4" />
          {t("customers.detail.breadcrumbList")}
        </button>
        <span className="text-[#C9C4BA]">/</span>
        <span className="font-semibold text-text">{customer.name}</span>
      </div>

      <div className="grid grid-cols-1 gap-4.5 lg:grid-cols-[2fr_1fr]">
        <Card className="gap-5">
          <div className="flex flex-wrap items-start justify-between gap-3 px-1">
            <div className="flex items-start gap-4.5">
              <span
                className="flex size-16 shrink-0 items-center justify-center rounded-[18px] text-[22px] font-extrabold"
                style={{ background: palette.bg, color: palette.fg }}
              >
                {initials(customer.name)}
              </span>
              <div>
                <h1 className="mb-1 text-[23px] font-extrabold tracking-tight text-text">{customer.name}</h1>
                <p className="mb-2.5 text-sm font-medium text-text-muted">{subtitleParts.join(" · ")}</p>
                <div className="flex flex-wrap gap-2">
                  {primaryAddress ? (
                    <>
                      <span className="rounded-full border border-border bg-surface-alt px-2.75 py-1 text-[11px] font-semibold text-text">
                        {t(`customers.form.${primaryAddress.address_type}`)} · {t(`customers.form.${primaryAddress.ownership}`)}
                      </span>
                      <span className="flex items-center gap-1 rounded-full border border-border bg-surface-alt px-2.75 py-1 text-[11px] font-semibold text-text">
                        <MapPin className="size-3" />
                        {[primaryAddress.door_no, primaryAddress.flat_no, primaryAddress.street_cross, primaryAddress.area, primaryAddress.pincode].filter(Boolean).join(", ")}
                      </span>
                    </>
                  ) : (
                    <span className="text-sm text-text-muted">{t("customers.detail.noAddress")}</span>
                  )}
                </div>
              </div>
            </div>
            <div className="flex items-center gap-1.5">
              <Button variant="outline" size="icon" title={t("customers.detail.call")} nativeButton={false} render={<a href={`tel:${customer.mobile}`} />}>
                <Phone className="size-4" />
              </Button>
              <Button variant="outline" size="icon" title={t("customers.detail.actions.edit")} onClick={() => navigate(`/admin/customers/${customer.id}/edit`)}>
                <Pencil className="size-4" />
              </Button>
            </div>
          </div>

          <div className="flex flex-wrap gap-2.25 border-t border-border px-1 pt-4">
            <Button onClick={() => navigate("/admin/sales/new")}>{t("customers.detail.actions.newSale")}</Button>
            <Button variant="outline" onClick={() => navigate(`/admin/service/new?customerId=${customer.id}`)}>
              {t("customers.detail.actions.newTicket")}
            </Button>
            <Button variant="ghost" className="bg-accent-soft text-accent hover:bg-accent-soft/80" onClick={() => navigate("/admin/amc")}>
              {t("customers.detail.actions.sellAmc")}
            </Button>
            <Button
              variant="ghost"
              className="bg-success/15 text-success hover:bg-success/25"
              nativeButton={false}
              render={<a href={`https://wa.me/91${waNumber}`} target="_blank" rel="noreferrer" />}
            >
              <MessageCircle className="size-3.5" />
              {t("customers.detail.whatsapp")}
            </Button>
          </div>
        </Card>

        <div className="relative flex flex-col justify-between overflow-hidden rounded-card bg-gradient-to-br from-ink to-[#33302C] p-5.5 text-white shadow-[0_14px_30px_-18px_rgba(26,26,26,.6)]">
          <div className="absolute -top-6 -right-6 size-27.5 rounded-full bg-accent/20" />
          <div className="relative">
            <span className="text-xs font-semibold text-white/70">{t("customers.detail.lifetimeValue")}</span>
            <div className="gv-tnum my-2 text-[30px] leading-none font-extrabold tracking-tight">
              {lifetime.isLoading ? "—" : formatCurrency(lifetime.data?.total ?? 0)}
            </div>
            <span className="text-xs font-medium text-white/70">{t("customers.detail.acrossInvoices", { count: lifetime.data?.invoiceCount ?? 0 })}</span>
          </div>
          <div className="relative mt-4.5 flex items-center gap-2.5 rounded-[14px] bg-white/10 p-3.25">
            <span className="flex size-7.5 shrink-0 items-center justify-center rounded-[9px] bg-accent">
              <Zap className="size-4 text-white" />
            </span>
            <div className="min-w-0 leading-tight">
              <div className="text-xs font-bold">{t("customers.detail.nextBestAction")}</div>
              <div className="truncate text-[11px] font-medium text-white/75">{nextActionLabel}</div>
            </div>
          </div>
        </div>
      </div>

      <Tabs defaultValue="products">
        <TabsList className="border border-border bg-surface p-1.25">
          <TabsTrigger value="products">
            {t("customers.detail.tabs.products")} ({products.data?.length ?? 0})
          </TabsTrigger>
          <TabsTrigger value="service">{t("customers.detail.tabs.service")}</TabsTrigger>
          <TabsTrigger value="invoices">{t("customers.detail.tabs.invoices")}</TabsTrigger>
          <TabsTrigger value="family">
            {t("customers.detail.tabs.family")} ({customer.customer_members.length})
          </TabsTrigger>
          <TabsTrigger value="exemptions">
            {t("customers.detail.tabs.exemptions")} ({(exemptionWindows.data ?? []).length})
          </TabsTrigger>
        </TabsList>

        <TabsContent value="products" className="mt-3.5">
          {renderProducts()}
        </TabsContent>
        <TabsContent value="service" className="mt-3.5">
          {renderServiceHistory()}
        </TabsContent>

        <TabsContent value="invoices" className="mt-3.5">
          <div className="overflow-hidden rounded-card border border-border bg-surface shadow-[0_1px_2px_rgba(26,26,26,.04),0_14px_30px_-22px_rgba(26,26,26,.16)]">
            <div className="grid grid-cols-[1fr_2fr_1fr_1fr] border-b border-border bg-surface-alt px-5.5 py-2.75">
              <span className="text-[11px] font-semibold tracking-wide text-text-muted uppercase">{t("customers.detail.invoicesTable.invoice")}</span>
              <span className="text-[11px] font-semibold tracking-wide text-text-muted uppercase">{t("customers.detail.invoicesTable.items")}</span>
              <span className="text-[11px] font-semibold tracking-wide text-text-muted uppercase">{t("customers.detail.invoicesTable.amount")}</span>
              <span className="text-[11px] font-semibold tracking-wide text-text-muted uppercase">{t("customers.detail.invoicesTable.date")}</span>
            </div>
            {invoices.isLoading ? (
              <div className="p-5.5">
                <Skeleton className="h-4 w-full" />
              </div>
            ) : (invoices.data ?? []).length === 0 ? (
              <EmptyTab icon={ReceiptText} label={t("customers.detail.emptyTabs.invoices")} />
            ) : (
              (invoices.data ?? []).map((inv, i, arr) => (
                <div key={inv.id} className={cn("grid grid-cols-[1fr_2fr_1fr_1fr] items-center px-5.5 py-3.25", i < arr.length - 1 && "border-b border-border")}>
                  <span className="gv-tnum text-xs font-bold text-text">#{inv.id.slice(0, 8).toUpperCase()}</span>
                  <span className="truncate pr-2 text-sm font-medium text-[#3A3A36]">{inv.itemsLabel}</span>
                  <span className="gv-tnum text-sm font-bold text-text">{formatCurrency(inv.total)}</span>
                  <span className="text-xs font-medium text-text-muted">{fmtDate(inv.createdAt)}</span>
                </div>
              ))
            )}
          </div>
        </TabsContent>

        <TabsContent value="family" className="mt-3.5">
          <Card size="default">
            <FamilyMembersPanel orgId={orgId} customerId={customer.id} members={customer.customer_members} />
          </Card>
        </TabsContent>

        <TabsContent value="exemptions" className="mt-3.5">
          <Card size="default">
            {exemptionWindows.isLoading ? (
              <Skeleton className="h-24 w-full" />
            ) : (
              <ExemptionWindowsPanel orgId={orgId} customerId={customer.id} windows={exemptionWindows.data ?? []} />
            )}
          </Card>
        </TabsContent>
      </Tabs>
    </div>
  )
}
