import { useMemo, useState } from "react"
import { useTranslation } from "react-i18next"
import { Plus, Search } from "lucide-react"
import { Button } from "@/components/ui/button"
import { DataTable, type DataTableColumn } from "@/components/shared/DataTable"
import { StatusDot, type StatusTone } from "@/components/shared/StatusDot"
import { SegButton } from "@/components/shared/SegButton"
import { useProfile } from "@/hooks/useProfile"
import { useMarkRentalReturned, useRentalContracts } from "@/hooks/useRentals"
import { RentOutPanel } from "./RentOutPanel"
import type { RentalContractListItem } from "@/services/rentals"

const STATUS_TONE: Record<string, StatusTone> = { active: "success", returned: "neutral" }

function fmt(date: string | null) {
  return date ? new Date(date).toLocaleDateString("en-IN") : "—"
}

export function RentalsListPage() {
  const { t } = useTranslation()
  const { data: profile } = useProfile()
  const orgId = profile?.org_id

  const [showRentOut, setShowRentOut] = useState(false)
  const [segment, setSegment] = useState<"active" | "returned">("active")
  const [search, setSearch] = useState("")

  const contracts = useRentalContracts(orgId)
  const markReturned = useMarkRentalReturned()

  const searchTerm = search.trim().toLowerCase()
  const filteredRows = useMemo(
    () =>
      (contracts.data ?? [])
        .filter((c) => c.status === segment)
        .filter(
          (c) =>
            !searchTerm ||
            (c.customers?.name ?? "").toLowerCase().includes(searchTerm) ||
            (c.customers?.mobile ?? "").includes(searchTerm) ||
            (c.products?.name ?? "").toLowerCase().includes(searchTerm)
        ),
    [contracts.data, segment, searchTerm]
  )

  const columns: DataTableColumn<RentalContractListItem>[] = [
    {
      key: "customer",
      header: t("rentals.list.customer"),
      render: (r) => (
        <div>
          <div className="font-medium text-text">{r.customers?.name ?? "—"}</div>
          <div className="text-xs text-text-muted">{r.customers?.mobile}</div>
        </div>
      ),
    },
    { key: "product", header: t("rentals.list.product"), render: (r) => r.products?.name ?? "—" },
    { key: "plan", header: t("rentals.list.plan"), render: (r) => r.rental_plans?.name ?? "—" },
    { key: "rate", header: t("rentals.list.monthlyRate"), render: (r) => `₹${r.rental_plans?.monthly_rate ?? "—"}/mo` },
    { key: "nextBilling", header: t("rentals.list.nextBilling"), render: (r) => fmt(r.next_billing_date) },
    { key: "nextService", header: t("rentals.list.nextService"), render: (r) => fmt(r.next_service_date) },
    { key: "status", header: t("rentals.list.status"), render: (r) => <StatusDot tone={STATUS_TONE[r.status] ?? "neutral"} label={t(`rentals.status.${r.status}`)} /> },
    {
      key: "actions",
      header: "",
      className: "text-right",
      render: (r) =>
        r.status === "active" ? (
          <Button
            size="sm"
            variant="outline"
            disabled={markReturned.isPending}
            onClick={(e) => {
              e.stopPropagation()
              if (window.confirm(t("rentals.list.confirmReturn"))) {
                markReturned.mutate({ orgId: orgId!, contractId: r.id })
              }
            }}
          >
            {t("rentals.list.markReturned")}
          </Button>
        ) : null,
    },
  ]

  return (
    <div className="space-y-4 pt-2">
      <div className="flex flex-wrap items-end justify-between gap-3">
        <div>
          <h1 className="text-2xl font-bold text-text">{t("nav.rentals")}</h1>
          <p className="text-sm text-text-muted">{t("rentals.subtitle")}</p>
        </div>
        <Button onClick={() => setShowRentOut((v) => !v)}>
          <Plus className="size-4" />
          {t("rentals.rentOut.title")}
        </Button>
      </div>

      {showRentOut ? (
        <RentOutPanel
          onClose={() => setShowRentOut(false)}
          onRented={() => {
            setShowRentOut(false)
            contracts.refetch()
          }}
        />
      ) : null}

      {markReturned.error ? <p className="rounded-xl bg-danger/10 px-3.5 py-2.5 text-sm text-danger">{(markReturned.error as Error).message}</p> : null}

      <div className="overflow-hidden rounded-card border border-border bg-surface shadow-[0_1px_2px_rgba(26,26,26,.04),0_14px_30px_-22px_rgba(26,26,26,.16)]">
        <div className="flex flex-wrap items-center justify-between gap-2 px-[22px] py-4">
          <div className="flex gap-[3px] rounded-full border border-border bg-surface-alt p-1">
            <SegButton active={segment === "active"} onClick={() => setSegment("active")}>
              {t("rentals.tabs.active")}
            </SegButton>
            <SegButton active={segment === "returned"} onClick={() => setSegment("returned")}>
              {t("rentals.tabs.returned")}
            </SegButton>
          </div>
          <div className="flex w-64 items-center gap-2.25 rounded-full border border-border bg-surface-alt px-3.5 py-2">
            <Search className="size-3.75 shrink-0 text-text-muted" />
            <input
              type="text"
              value={search}
              onChange={(e) => setSearch(e.target.value)}
              placeholder={t("rentals.list.search")}
              className="w-full bg-transparent text-xs font-medium text-text outline-none placeholder:text-text-muted"
            />
          </div>
        </div>

        <DataTable
          columns={columns}
          rows={filteredRows}
          rowKey={(r) => r.id}
          loading={contracts.isLoading}
          error={contracts.isError ? t("rentals.list.loadFailed") : null}
          onRetry={() => contracts.refetch()}
          emptyMessage={t("rentals.list.empty")}
        />
      </div>
    </div>
  )
}
