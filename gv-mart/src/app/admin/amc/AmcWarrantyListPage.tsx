import { useEffect, useMemo, useState } from "react"
import { useTranslation } from "react-i18next"
import { Plus } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Card } from "@/components/ui/card"
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs"
import { DataTable, type DataTableColumn } from "@/components/shared/DataTable"
import { StatusDot, type StatusTone } from "@/components/shared/StatusDot"
import { useProfile } from "@/hooks/useProfile"
import { useAmcContracts, useRefreshAmcStatuses, useWarranties } from "@/hooks/useAmc"
import { useSettings } from "@/hooks/useMasters"
import { SellAmcPanel } from "./SellAmcPanel"
import type { AmcContractListItem, WarrantyListItem } from "@/services/amc"

const AMC_STATUS_TONE: Record<string, StatusTone> = { active: "success", due_soon: "warning", expired: "danger" }
const WARRANTY_STATUS_TONE: Record<string, StatusTone> = { active: "success", due_soon: "warning", expired: "danger" }

function fmt(date: string | null) {
  return date ? new Date(date).toLocaleDateString("en-IN") : "—"
}

function warrantyStatus(expiryDate: string, windowDays: number): "active" | "due_soon" | "expired" {
  const today = new Date()
  const expiry = new Date(expiryDate)
  const diffDays = (expiry.getTime() - today.getTime()) / 86_400_000
  if (diffDays < 0) return "expired"
  if (diffDays <= windowDays) return "due_soon"
  return "active"
}

export function AmcWarrantyListPage() {
  const { t } = useTranslation()
  const { data: profile } = useProfile()
  const orgId = profile?.org_id
  const [showSellAmc, setShowSellAmc] = useState(false)

  const { data: settings } = useSettings(orgId)
  const windowDays = settings ? settings.amc_book_window_days : 15

  const contracts = useAmcContracts(orgId)
  const warranties = useWarranties(orgId)
  const refreshStatuses = useRefreshAmcStatuses(orgId)

  useEffect(() => {
    if (orgId) refreshStatuses.mutate()
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [orgId])

  const warrantyRows = useMemo(
    () => (warranties.data ?? []).map((w) => ({ ...w, computedStatus: warrantyStatus(w.expiry_date, windowDays) })),
    [warranties.data, windowDays]
  )

  const amcColumns: DataTableColumn<AmcContractListItem>[] = [
    {
      key: "customer",
      header: t("amc.list.customer"),
      render: (c) => (
        <div>
          <div className="font-medium text-text">{c.customers?.name ?? "—"}</div>
          <div className="text-xs text-text-muted">{c.customers?.mobile}</div>
        </div>
      ),
    },
    { key: "product", header: t("amc.list.product"), render: (c) => c.products?.name ?? "—" },
    { key: "plan", header: t("amc.list.plan"), render: (c) => (c.amc_plans ? `${c.amc_plans.name} (${c.amc_plans.years}y)` : "—") },
    { key: "start", header: t("amc.list.start"), render: (c) => fmt(c.start_date) },
    { key: "expiry", header: t("amc.list.expiry"), render: (c) => fmt(c.expiry_date) },
    { key: "nextService", header: t("amc.list.nextService"), render: (c) => fmt(c.next_service_date) },
    { key: "status", header: t("amc.list.status"), render: (c) => <StatusDot tone={AMC_STATUS_TONE[c.status] ?? "neutral"} label={t(`amc.status.${c.status}`)} /> },
  ]

  const warrantyColumns: DataTableColumn<WarrantyListItem & { computedStatus: string }>[] = [
    {
      key: "customer",
      header: t("amc.list.customer"),
      render: (w) => (
        <div>
          <div className="font-medium text-text">{w.customers?.name ?? "—"}</div>
          <div className="text-xs text-text-muted">{w.customers?.mobile}</div>
        </div>
      ),
    },
    { key: "product", header: t("amc.list.product"), render: (w) => w.products?.name ?? "—" },
    { key: "start", header: t("amc.list.start"), render: (w) => fmt(w.start_date) },
    { key: "expiry", header: t("amc.list.expiry"), render: (w) => fmt(w.expiry_date) },
    {
      key: "status",
      header: t("amc.list.status"),
      render: (w) => <StatusDot tone={WARRANTY_STATUS_TONE[w.computedStatus] ?? "neutral"} label={t(`amc.status.${w.computedStatus}`)} />,
    },
  ]

  return (
    <div className="space-y-4 pt-2">
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <h1 className="text-2xl font-bold text-text">{t("nav.amcWarranty")}</h1>
          <p className="text-sm text-text-muted">{t("amc.list.subtitle", { days: windowDays })}</p>
        </div>
        <Button variant="accent" onClick={() => setShowSellAmc((v) => !v)}>
          <Plus className="size-4" />
          {t("amc.sellAmc.title")}
        </Button>
      </div>

      {showSellAmc ? (
        <SellAmcPanel
          onClose={() => setShowSellAmc(false)}
          onSold={() => {
            setShowSellAmc(false)
            contracts.refetch()
          }}
        />
      ) : null}

      <Tabs defaultValue="amc">
        <TabsList>
          <TabsTrigger value="amc">{t("amc.tabs.amc")}</TabsTrigger>
          <TabsTrigger value="warranty">{t("amc.tabs.warranty")}</TabsTrigger>
        </TabsList>
        <Card size="default" className="mt-3">
          <TabsContent value="amc">
            <DataTable
              columns={amcColumns}
              rows={contracts.data ?? []}
              rowKey={(c) => c.id}
              loading={contracts.isLoading}
              error={contracts.isError ? t("amc.list.loadFailed") : null}
              onRetry={() => contracts.refetch()}
              emptyMessage={t("amc.list.emptyAmc")}
            />
          </TabsContent>
          <TabsContent value="warranty">
            <DataTable
              columns={warrantyColumns}
              rows={warrantyRows}
              rowKey={(w) => w.id}
              loading={warranties.isLoading}
              error={warranties.isError ? t("amc.list.loadFailed") : null}
              onRetry={() => warranties.refetch()}
              emptyMessage={t("amc.list.emptyWarranty")}
            />
          </TabsContent>
        </Card>
      </Tabs>
    </div>
  )
}
