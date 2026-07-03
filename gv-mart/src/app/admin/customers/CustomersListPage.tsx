import { useMemo, useState } from "react"
import { useTranslation } from "react-i18next"
import { useNavigate } from "react-router-dom"
import { Download, Plus, Search, UserPlus, X } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Card } from "@/components/ui/card"
import { DataTable, type DataTableColumn } from "@/components/shared/DataTable"
import { StatusDot } from "@/components/shared/StatusDot"
import { Autocomplete } from "@/components/shared/Autocomplete"
import { useProfile } from "@/hooks/useProfile"
import { useCustomerAutocomplete, useCustomersList } from "@/hooks/useCustomers"
import { useDebouncedValue } from "@/hooks/useDebouncedValue"
import type { CustomerListItem } from "@/services/customers"
import type { Enums } from "@/types/database"

function toCsv(rows: CustomerListItem[]) {
  const header = ["Name", "Mobile", "Profession", "Area", "Pincode", "Members"]
  const lines = rows.map((r) => {
    const primary = r.addresses.find((a) => a.is_primary) ?? r.addresses[0]
    return [r.name, r.mobile, r.profession ?? "", primary?.area ?? "", primary?.pincode ?? "", String(r.member_count[0]?.count ?? 1)]
      .map((v) => `"${String(v).replace(/"/g, '""')}"`)
      .join(",")
  })
  return [header.join(","), ...lines].join("\n")
}

export function CustomersListPage() {
  const { t } = useTranslation()
  const navigate = useNavigate()
  const { data: profile } = useProfile()
  const orgId = profile?.org_id

  const [searchInput, setSearchInput] = useState("")
  const search = useDebouncedValue(searchInput, 300)
  const [addressType, setAddressType] = useState<Enums<"address_type"> | "">("")
  const [area, setArea] = useState("")
  const [pincode, setPincode] = useState("")
  const [hasAmc, setHasAmc] = useState(false)
  const [hasWarranty, setHasWarranty] = useState(false)
  const [page, setPage] = useState(1)

  const filters = useMemo(
    () => ({
      search: search || undefined,
      addressType: addressType || undefined,
      area: area || undefined,
      pincode: pincode || undefined,
      hasAmc: hasAmc || undefined,
      hasWarranty: hasWarranty || undefined,
    }),
    [search, addressType, area, pincode, hasAmc, hasWarranty]
  )
  const hasActiveFilters = !!(search || addressType || area || pincode || hasAmc || hasWarranty)

  const { data, isLoading, isFetching, isError, refetch } = useCustomersList(orgId, filters, page)
  const autocomplete = useCustomerAutocomplete(orgId, searchInput)

  const totalPages = data ? Math.max(1, Math.ceil(data.count / (data.pageSize ?? 20))) : 1

  function clearFilters() {
    setSearchInput("")
    setAddressType("")
    setArea("")
    setPincode("")
    setHasAmc(false)
    setHasWarranty(false)
    setPage(1)
  }

  function exportCsv() {
    if (!data?.rows.length) return
    const blob = new Blob([toCsv(data.rows)], { type: "text/csv;charset=utf-8;" })
    const url = URL.createObjectURL(blob)
    const a = document.createElement("a")
    a.href = url
    a.download = `gv-mart-customers-${new Date().toISOString().slice(0, 10)}.csv`
    a.click()
    URL.revokeObjectURL(url)
  }

  const columns: DataTableColumn<CustomerListItem>[] = [
    {
      key: "name",
      header: t("customers.table.name"),
      render: (c) => (
        <div>
          <div className="font-medium text-text">{c.name}</div>
          <div className="text-xs text-text-muted">{c.mobile}</div>
        </div>
      ),
    },
    {
      key: "area",
      header: t("customers.table.area"),
      render: (c) => {
        const primary = c.addresses.find((a) => a.is_primary) ?? c.addresses[0]
        return primary ? `${primary.area ?? "—"} · ${primary.pincode ?? "—"}` : "—"
      },
    },
    { key: "profession", header: t("customers.table.profession"), render: (c) => c.profession || "—" },
    { key: "members", header: t("customers.table.members"), render: (c) => c.member_count[0]?.count ?? 1 },
    {
      key: "amc",
      header: t("customers.table.amc"),
      render: () => <StatusDot tone="neutral" label={t("customers.table.notAvailable")} />,
    },
    { key: "lastService", header: t("customers.table.lastService"), render: () => "—" },
  ]

  return (
    <div className="space-y-4 pt-2">
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <h1 className="text-2xl font-bold text-text">{t("customers.title")}</h1>
          <p className="text-sm text-text-muted">{t("customers.subtitle")}</p>
        </div>
        <div className="flex items-center gap-2">
          <Button variant="outline" onClick={exportCsv} disabled={!data?.rows.length}>
            <Download className="size-4" />
            {t("customers.exportButton")}
          </Button>
          <Button variant="accent" onClick={() => navigate("/admin/customers/new")}>
            <Plus className="size-4" />
            {t("customers.addButton")}
          </Button>
        </div>
      </div>

      <Card className="gap-3">
        <div className="flex flex-wrap items-center gap-2 px-1">
          <Autocomplete
            className="min-w-56 flex-1"
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
              setHasAmc((v) => !v)
              setPage(1)
            }}
            className={`h-10 rounded-full border px-3.5 text-sm font-medium transition-colors ${
              hasAmc ? "border-accent bg-accent-soft text-accent" : "border-border bg-surface text-text-muted"
            }`}
          >
            {t("customers.filters.hasAmc")}
          </button>
          <button
            type="button"
            onClick={() => {
              setHasWarranty((v) => !v)
              setPage(1)
            }}
            className={`h-10 rounded-full border px-3.5 text-sm font-medium transition-colors ${
              hasWarranty ? "border-accent bg-accent-soft text-accent" : "border-border bg-surface text-text-muted"
            }`}
          >
            {t("customers.filters.hasWarranty")}
          </button>

          {hasActiveFilters ? (
            <button type="button" onClick={clearFilters} className="flex h-10 items-center gap-1 rounded-full px-3 text-sm text-text-muted hover:text-text">
              <X className="size-3.5" />
              {t("customers.filters.clearFilters")}
            </button>
          ) : null}
        </div>
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
              <Button variant="accent" onClick={() => navigate("/admin/customers/new")}>
                {t("customers.empty.addFirstButton")}
              </Button>
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
