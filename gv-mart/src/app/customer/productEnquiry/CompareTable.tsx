import { useTranslation } from "react-i18next"
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table"
import type { Enums, Tables } from "@/types/database"

type ComparisonField = Tables<"product_enquiry_comparison_fields"> & { product_attribute_keys: { id: string; label: string; data_type: string } | null }
type CompareProduct = Tables<"products"> & { brands: { name: string } | null; models: { name: string } | null }

function resolveFieldValue(field: ComparisonField, product: CompareProduct, t: (key: string) => string): string {
  if (field.attribute_key_id) {
    const value = (product.custom_attributes as Record<string, unknown>)?.[field.attribute_key_id]
    return value == null ? "—" : String(value)
  }
  switch (field.product_field as Enums<"product_enquiry_field"> | null) {
    case "category":
      return t(`customerApp.productEnquiry.compare.category.${product.category}`)
    case "brand":
      return product.brands?.name ?? "—"
    case "price_range":
      return `₹${product.price.toLocaleString("en-IN")}`
    default:
      return "—"
  }
}

/**
 * Product Enquiry rebuild (2026-08-04), Phase 5 — pivots admin-configured
 * comparison fields (rows) × selected products (columns). A field is
 * resolved either from a fixed base product column (category/brand/price)
 * or from custom_attributes, keyed by the field's attribute_key_id — same
 * resolution the detail page uses for its own attribute list.
 */
export function CompareTable({ fields, products }: { fields: ComparisonField[]; products: CompareProduct[] }) {
  const { t } = useTranslation()

  return (
    <Table>
      <TableHeader>
        <TableRow>
          <TableHead>{t("customerApp.productEnquiry.compare.field")}</TableHead>
          {products.map((p) => (
            <TableHead key={p.id}>{p.name}</TableHead>
          ))}
        </TableRow>
      </TableHeader>
      <TableBody>
        {fields.map((field) => (
          <TableRow key={field.id}>
            <TableCell className="font-medium text-text">{field.label}</TableCell>
            {products.map((p) => (
              <TableCell key={p.id} className="text-text-muted">
                {resolveFieldValue(field, p, t)}
              </TableCell>
            ))}
          </TableRow>
        ))}
      </TableBody>
    </Table>
  )
}
