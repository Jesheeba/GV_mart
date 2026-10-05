import { formatCurrency } from "@/lib/sale-calc"
import type { TopCustomerRow } from "@/services/reports"

export type TopCustomerFieldKey =
  | "rank"
  | "name"
  | "mobile"
  | "profession"
  | "area"
  | "pincode"
  | "invoicedTotal"
  | "collectedTotal"
  | "invoiceCount"
  | "firstPurchaseAt"
  | "lastPurchaseAt"

export type TopCustomerFieldDef = {
  key: TopCustomerFieldKey
  labelKey: string
  align?: "right"
  format: (row: TopCustomerRow) => string
}

function fmtDate(iso: string) {
  return new Date(iso).toLocaleDateString("en-IN", { day: "2-digit", month: "short", year: "numeric" })
}

// Order here is both the field-picker checklist order and the printed
// column order (left to right), so reordering this array is the one place
// to change either.
export const TOP_CUSTOMER_FIELDS: TopCustomerFieldDef[] = [
  { key: "rank", labelKey: "reports.topCustomers.fields.rank", format: (r) => String(r.rank) },
  { key: "name", labelKey: "reports.topCustomers.fields.name", format: (r) => r.name },
  { key: "mobile", labelKey: "reports.topCustomers.fields.mobile", format: (r) => r.mobile },
  { key: "profession", labelKey: "reports.topCustomers.fields.profession", format: (r) => r.profession ?? "—" },
  { key: "area", labelKey: "reports.topCustomers.fields.area", format: (r) => r.area ?? "—" },
  { key: "pincode", labelKey: "reports.topCustomers.fields.pincode", format: (r) => r.pincode ?? "—" },
  { key: "invoicedTotal", labelKey: "reports.topCustomers.fields.invoicedTotal", align: "right", format: (r) => formatCurrency(r.invoicedTotal) },
  { key: "collectedTotal", labelKey: "reports.topCustomers.fields.collectedTotal", align: "right", format: (r) => formatCurrency(r.collectedTotal) },
  { key: "invoiceCount", labelKey: "reports.topCustomers.fields.invoiceCount", align: "right", format: (r) => String(r.invoiceCount) },
  { key: "firstPurchaseAt", labelKey: "reports.topCustomers.fields.firstPurchaseAt", format: (r) => fmtDate(r.firstPurchaseAt) },
  { key: "lastPurchaseAt", labelKey: "reports.topCustomers.fields.lastPurchaseAt", format: (r) => fmtDate(r.lastPurchaseAt) },
]

export const DEFAULT_TOP_CUSTOMER_FIELDS: TopCustomerFieldKey[] = [
  "rank",
  "name",
  "mobile",
  "area",
  "invoicedTotal",
  "collectedTotal",
]
