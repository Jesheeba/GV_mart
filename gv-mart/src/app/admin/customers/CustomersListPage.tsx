import { useMemo, useState } from "react"
import { useTranslation } from "react-i18next"
import { useNavigate } from "react-router-dom"
import { Download, Plus, Search, SlidersHorizontal, UserPlus, X } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Card } from "@/components/ui/card"
import { DataTable, type DataTableColumn } from "@/components/shared/DataTable"
import { StatusDot } from "@/components/shared/StatusDot"
import { Autocomplete } from "@/components/shared/Autocomplete"
import { useProfile } from "@/hooks/useProfile"
import {
  useCustomerAutocomplete,
  useCustomerFilterCounts,
  useCustomerListEnrichment,
  useCustomersList,
} from "@/hooks/useCustomers"
import { useDebouncedValue } from "@/hooks/useDebouncedValue"
import { avatarPalette, initials } from "@/lib/avatar"
import { AMC_STATUS_TONE } from "@/lib/amc-status"
import { cn } from "@/lib/utils"
import { getCustomerListEnrichment, listCustomers } from "@/services/customers"
import type { CustomerListItem, CustomerRowEnrichment } from "@/services/customers"
import type { Enums } from "@/types/database"

type QuickFilter = "all" | "hasAmc" | "amcDueSoon" | "dormant"

function toCsv(
  rows: CustomerListItem[],
  header: string[],
  enrichment: Map<string, CustomerRowEnrichment> | undefined,
  amcStatusLabel: (status: string) => string
) {
  const lines = rows.map((r) => {
    const primary = r.addresses.find((a) => a.is_primary) ?? r.addresses[0]
    const info = enrichment?.get(r.id)
    return [
      r.name,
      r.mobile,
      r.profession ?? "",
      primary?.area ?? "",
      primary?.pincode ?? "",
      String(r.member_count[0]?.count ?? 1),
      info?.amcStatus ? amcStatusLabel(info.amcStatus) : "",
      fmtDate(info?.lastServiceAt),
    ]
      .map((v) => `"${String(v).replace(/"/g, '""')}"`)
      .join(",")
  })
  return [header.join(","), ...lines].join("\n")
}

function fmtDate(iso: string | null | undefined) {
  if (!iso) return "—"
  return new Date(iso).toLocaleDateString("en-IN", { day: "2-digit", month: "short", year: "2-digit" })
}

function QuickFilterChip({ active, label, onClick }: { active: boolean; label: string; onClick: () => void }) {
  return (
    <button
      type="button"
      onClick={onClick}
      className={cn(
        "rounded-full px-4 py-2 text-xs font-bold whitespace-nowrap transition-colors",
        active ? "bg-ink text-white" : "border border-border bg-surface text-text"
      )}
    >
      {label}
    </button>
  )
}

export function CustomersListPage() {
  const { t } = useTranslation()
  const navigate = useNavigate()
  const { data: profile } = useProfile()
  const orgId = profile?.org_id

  const [searchInput, setSearchInput] = useState("")
  const search = useDebouncedValue(searchInput, 300)
  const [quickFilter, setQuickFilter] = useState<QuickFilter>("all")
  const [showFilters, setShowFilters] = useState(false)
  const [addressType, setAddressType] = useState<Enums<"address_type"> | "">("")
  const [area, setArea] = useState("")
  const [pincode, setPincode] = useState("")
  const [hasWarranty, setHasWarranty] = useState(false)
  const [page, setPage] = useState(1)
  const [isExporting, setIsExporting] = useState(false)

  const filters = useMemo(
    () => ({
      search: search || undefined,
      addressType: addressType || undefined,
      area: area || undefined,
      pincode: pincode || undefined,
      hasWarranty: hasWarranty || undefined,
      hasAmc: quickFilter === "hasAmc" ? true : undefined,
      amcDueSoon: quickFilter === "amcDueSoon" ? true : undefined,
      dormant: quickFilter === "dormant" ? true : undefined,
    }),
    [search, addressType, area, pincode, hasWarranty, quickFilter]
  )
  const hasActiveFilters = !!(search || addressType || area || pincode || hasWarranty || quickFilter !== "all")

  const { data, isLoading, isFetching, isError, refetch } = useCustomersList(orgId, filters, page)
  const autocomplete = useCustomerAutocomplete(orgId, searchInput)
  const counts = useCustomerFilterCounts(orgId)
  const enrichment = useCustomerListEnrichment(
    orgId,
    (data?.rows ?? []).map((r) => r.id)
  )

  const totalPages = data ? Math.max(1, Math.ceil(data.count / (data.pageSize ?? 20))) : 1

  function clearFilters() {
    setSearchInput("")
    setQuickFilter("all")
    setAddressType("")
    setArea("")
    setPincode("")
    setHasWarranty(false)
    setPage(1)
  }

  async function exportCsv() {
    if (!orgId || !data?.count) return
    setIsExporting(true)
    try {
      const pageSize = data.pageSize ?? 20
      const pageCount = Math.max(1, Math.ceil(data.count / pageSize))
      const pages = await Promise.all(
        Array.from({ length: pageCount }, (_, i) => listCustomers(orgId, filters, i + 1))
      )
      const rows = pages.flatMap((p) => p.rows)
      const enrichmentMap = await getCustomerListEnrichment(
        orgId,
        rows.map((r) => r.id)
      )
      const header = [
        t("customers.export.name"),
        t("customers.export.mobile"),
        t("customers.export.profession"),
        t("customers.export.area"),
        t("customers.export.pincode"),
        t("customers.export.members"),
        t("customers.table.amc"),
        t("customers.table.lastService"),
      ]
      const blob = new Blob([toCsv(rows, header, enrichmentMap, (status) => t(`amc.status.${status}`))], {
        type: "text/csv;charset=utf-8;",
      })
      const url = URL.createObjectURL(blob)
      const a = document.createElement("a")
      a.href = url
      a.download = `gv-mart-customers-${new Date().toISOString().slice(0, 10)}.csv`
      a.click()
      URL.revokeObjectURL(url)
    } finally {
      setIsExporting(false)
    }
  }

  const columns: DataTableColumn<CustomerListItem>[] = [
    {
      key: "customer",
      header: t("customers.table.customer"),
      render: (c) => {
        const palette = avatarPalette(c.name)
        return (
          <div className="flex items-center gap-2.75">
            <span
              className="flex size-9 shrink-0 items-center justify-center rounded-[11px] text-xs font-bold"
              style={{ background: palette.bg, color: palette.fg }}
            >
              {initials(c.name)}
            </span>
            <div className="leading-tight">
              <div className="font-semibold text-text">{c.name}</div>
              <div className="gv-tnum text-xs text-text-muted">{c.mobile}</div>
            </div>
          </div>
        )
      },
    },
    {
      key: "area",
      header: t("customers.table.area"),
      render: (c) => {
        const primary = c.addresses.find((a) => a.is_primary) ?? c.addresses[0]
        return primary?.area ?? "—"
      },
    },
    {
      key: "products",
      header: t("customers.table.products"),
      render: (c) => (enrichment.isLoading ? "…" : (enrichment.data?.get(c.id)?.productCount ?? 0)),
    },
    {
      key: "amc",
      header: t("customers.table.amc"),
      render: (c) => {
        if (enrichment.isLoading) return <span className="text-text-muted">…</span>
        const status = enrichment.data?.get(c.id)?.amcStatus ?? null
        if (!status) return <StatusDot tone="neutral" label={t("customers.table.noAmc")} />
        return <StatusDot tone={AMC_STATUS_TONE[status] ?? "neutral"} label={t(`amc.status.${status}`)} />
      },
    },
    {
      key: "lastService",
      header: t("customers.table.lastService"),
      render: (c) => (enrichment.isLoading ? "…" : fmtDate(enrichment.data?.get(c.id)?.lastServiceAt)),
    },
  ]

  return (
    <div className="space-y-4 pt-2">
      <div className="flex flex-wrap items-end justify-between gap-3">
        <div>
          <p className="mb-1.5 text-xs font-semibold tracking-wide text-text-muted">{t("customers.eyebrow")}</p>
          <h1 className="text-[28px] leading-[1.05] font-extrabold tracking-tight text-text">{t("customers.title")}</h1>
          <p className="mt-1.5 text-sm font-medium text-text-muted">
            {counts.data
              ? t("customers.statsLine", { total: counts.data.total, hasAmc: counts.data.hasAmc, dormant: counts.data.dormant })
              : t("customers.subtitle")}
          </p>
        </div>
        <div className="flex items-center gap-2.5">
          <Button variant="outline" className="border-[#DAD5CC]" onClick={exportCsv} disabled={!data?.rows.length || isExporting}>
            <Download className="size-4" />
            {isExporting ? t("common.loading") : t("customers.exportButton")}
          </Button>
          <Button onClick={() => navigate("/admin/customers/new")} className="shadow-[0_10px_20px_-12px_rgba(26,26,26,0.6)]">
            <Plus className="size-4" />
            {t("customers.addButton")}
          </Button>
        </div>
      </div>

      <div className="flex flex-wrap gap-2.5">
        <QuickFilterChip
          active={quickFilter === "all"}
          label={`${t("customers.filters.quickAll")} · ${counts.data?.total ?? "—"}`}
          onClick={() => {
            setQuickFilter("all")
            setPage(1)
          }}
        />
        <QuickFilterChip
          active={quickFilter === "hasAmc"}
          label={`${t("customers.filters.hasAmc")} · ${counts.data?.hasAmc ?? "—"}`}
          onClick={() => {
            setQuickFilter("hasAmc")
            setPage(1)
          }}
        />
        <QuickFilterChip
          active={quickFilter === "amcDueSoon"}
          label={`${t("customers.filters.amcDueSoon")} · ${counts.data?.amcDueSoon ?? "—"}`}
          onClick={() => {
            setQuickFilter("amcDueSoon")
            setPage(1)
          }}
        />
        <QuickFilterChip
          active={quickFilter === "dormant"}
          label={`${t("customers.filters.dormant")} · ${counts.data?.dormant ?? "—"}`}
          onClick={() => {
            setQuickFilter("dormant")
            setPage(1)
          }}
        />
      </div>

      <Card className="gap-3">
        <div className="flex flex-wrap items-center gap-2.5 px-1">
          <Autocomplete
            className="min-w-56 flex-1"
            inputClassName="rounded-full border-border bg-surface-alt"
            value={searchInput}
            onChange={(v) => {
              setSearchInput(v)
              setPage(1)
            }}
            suggestions={autocomplete.data ?? []}
            loading={autocomplete.isFetching}
            placeholder={t("customers.searchPlaceholder")}
            icon={<Search className="size-4" />}
            emptyMessage={t("common.noData")}
            getKey={(c) => c.id}
            getLabel={(c) => (
              <span>
                <span className="font-medium">{c.name}</span> <span className="text-text-muted">{c.mobile}</span>
              </span>
            )}
            onSelect={(c) => navigate(`/admin/customers/${c.id}`)}
          />

          <Button type="button" variant="outline" onClick={() => setShowFilters((v) => !v)}>
            <SlidersHorizontal className="size-3.5" />
            {t("customers.filters.moreFilters")}
          </Button>

          {hasActiveFilters ? (
            <button type="button" onClick={clearFilters} className="flex h-10 items-center gap-1 rounded-full px-3 text-sm text-text-muted hover:text-text">
              <X className="size-3.5" />
              {t("customers.filters.clearFilters")}
            </button>
          ) : null}
        </div>

        {showFilters ? (
          <div className="flex flex-wrap items-center gap-2 border-t border-border px-1 pt-3">
            <select
              value={addressType}
              onChange={(e) => {
                setAddressType(e.target.value as Enums<"address_type"> | "")
                setPage(1)
              }}
              className="h-10 rounded-full border border-border bg-surface px-3.5 text-sm text-text outline-none"
            >
              <option value="">{t("customers.filters.allTypes")}</option>
              <option value="residential">{t("customers.filters.residential")}</option>
              <option value="commercial">{t("customers.filters.commercial")}</option>
            </select>

            <input
              value={area}
              onChange={(e) => {
                setArea(e.target.value)
                setPage(1)
              }}
              placeholder={t("customers.filters.area")}
              className="h-10 w-32 rounded-full border border-border bg-surface px-3.5 text-sm text-text outline-none placeholder:text-text-muted"
            />
            <input
              value={pincode}
              onChange={(e) => {
                setPincode(e.target.value)
                setPage(1)
              }}
              placeholder={t("customers.filters.pincodePlaceholder")}
              maxLength={6}
              className="h-10 w-28 rounded-full border border-border bg-surface px-3.5 text-sm text-text outline-none placeholder:text-text-muted"
            />

            <button
              type="button"
              onClick={() => {
                setHasWarranty((v) => !v)
                setPage(1)
              }}
              className={cn(
                "h-10 rounded-full border px-3.5 text-sm font-medium transition-colors",
                hasWarranty ? "border-accent bg-accent-soft text-accent" : "border-border bg-surface text-text-muted"
              )}
            >
              {t("customers.filters.hasWarranty")}
            </button>
          </div>
        ) : null}
      </Card>

      <Card size="default">
        {data && data.rows.length === 0 && !isLoading ? (
          <div className="flex flex-col items-center gap-3 py-12 text-center">
            <span className="flex size-12 items-center justify-center rounded-full bg-surface-alt text-text-muted">
              <UserPlus className="size-6" />
            </span>
            <h2 className="text-lg font-semibold text-text">
              {hasActiveFilters ? t("customers.empty.titleFiltered") : t("customers.empty.title")}
            </h2>
            <p className="max-w-xs text-sm text-text-muted">{t("customers.empty.subtitle")}</p>
            {hasActiveFilters ? (
              <Button variant="outline" onClick={clearFilters}>
                {t("customers.empty.clearFiltersButton")}
              </Button>
            ) : (
              <Button onClick={() => navigate("/admin/customers/new")}>{t("customers.empty.addFirstButton")}</Button>
            )}
          </div>
        ) : (
          <DataTable
            columns={columns}
            rows={data?.rows ?? []}
            rowKey={(c) => c.id}
            onRowClick={(c) => navigate(`/admin/customers/${c.id}`)}
            loading={isLoading}
            error={isError ? t("customers.error.loadFailed") : null}
            onRetry={() => refetch()}
            emptyMessage={t("customers.empty.title")}
          />
        )}

        {data && data.count > 0 ? (
          <div className="flex items-center justify-between px-1 pt-1">
            <p className="text-xs text-text-muted">
              {t("customers.pagination.pageInfo", { page, totalPages, count: data.count })}
              {isFetching ? ` · ${t("common.loading")}` : ""}
            </p>
            <div className="flex gap-2">
              <Button variant="outline" size="sm" disabled={page <= 1} onClick={() => setPage((p) => p - 1)}>
                {t("customers.pagination.prev")}
              </Button>
              <Button variant="outline" size="sm" disabled={page >= totalPages} onClick={() => setPage((p) => p + 1)}>
                {t("customers.pagination.next")}
              </Button>
            </div>
          </div>
        ) : null}
      </Card>
    </div>
  )
}
