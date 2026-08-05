import { useEffect, useState } from "react"
import { useTranslation } from "react-i18next"
import { useNavigate } from "react-router-dom"
import { zodResolver } from "@hookform/resolvers/zod"
import { useForm } from "react-hook-form"
import { ArrowLeft, CheckCircle2, Loader2, Plus, X } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { Card } from "@/components/ui/card"
import { FullPageError, FullPageLoader } from "@/components/shared/FullPageLoader"
import { AddressPickerModal } from "@/components/shared/AddressPickerModal"
import { useMyAddresses, useMyCustomerId, useOwnedProducts, useSparesForProduct, useSubmitEnquiry } from "@/hooks/useCustomerApp"
import { enquirySchema, type EnquiryInput } from "@/lib/validation/customerApp"

const DESCRIPTION_FIELD_ID = "spare-enquiry-description"
const CATEGORIES = ["ro", "ac", "inverter", "battery"] as const

type Product = NonNullable<ReturnType<typeof useOwnedProducts>["data"]>[number]

// Multi-product spare enquiry (2026-08-05) — each row carries its own
// category/product/spare pick plus the resolved display labels (computed by
// the row itself, since only it has the per-product spares list loaded), so
// the parent can build the combined description without re-fetching.
type SpareEnquiryRowState = {
  id: string
  category: (typeof CATEGORIES)[number] | ""
  productId: string
  productLabel: string
  customProductName: string
  spareId: string
  spareLabel: string
  manualSpare: boolean
}

function emptyRow(): SpareEnquiryRowState {
  return { id: crypto.randomUUID(), category: "", productId: "", productLabel: "", customProductName: "", spareId: "", spareLabel: "", manualSpare: false }
}

function SpareEnquiryProductRow({
  row,
  products,
  canRemove,
  onChange,
  onRemove,
}: {
  row: SpareEnquiryRowState
  products: Product[]
  canRemove: boolean
  onChange: (patch: Partial<SpareEnquiryRowState>) => void
  onRemove: () => void
}) {
  const { t } = useTranslation()
  const { data: sparesForProduct, isLoading: loadingSpares } = useSparesForProduct(row.productId || undefined)
  const hasMappedSpares = (sparesForProduct ?? []).length > 0
  const categoryProducts = products.filter((p) => !row.category || p.category === row.category)

  const productFieldId = `spare-enquiry-product-${row.id}`
  const customNameFieldId = `spare-enquiry-custom-product-name-${row.id}`
  const spareFieldId = `spare-enquiry-spare-${row.id}`

  return (
    <div className="space-y-3 rounded-xl border border-border p-3">
      {canRemove ? (
        <div className="flex justify-end">
          <Button type="button" size="icon-xs" variant="ghost" onClick={onRemove} aria-label={t("common.remove")}>
            <X className="size-4" />
          </Button>
        </div>
      ) : null}

      <div className="space-y-1.5">
        <Label>{t("customerApp.spareEnquiry.whatLookingFor")}</Label>
        <div className="flex flex-wrap gap-1.5">
          {CATEGORIES.map((cat) => (
            <button
              key={cat}
              type="button"
              onClick={() => onChange({ category: row.category === cat ? "" : cat, productId: "", productLabel: "", spareId: "", spareLabel: "", manualSpare: false })}
              aria-pressed={row.category === cat}
              className={`rounded-full border px-3 py-1.5 text-sm font-medium ${row.category === cat ? "border-accent bg-accent text-white" : "border-border text-text-muted"}`}
            >
              {t(`customerApp.bookService.category.${cat}`)}
            </button>
          ))}
        </div>
      </div>

      <div className="space-y-1.5">
        <Label htmlFor={productFieldId}>{t("customerApp.spareEnquiry.selectProduct")}</Label>
        <select
          id={productFieldId}
          value={row.productId}
          onChange={(e) => {
            const p = categoryProducts.find((x) => x.id === e.target.value)
            const label = p ? [p.name, p.brands?.name, p.models?.name].filter(Boolean).join(" · ") : ""
            onChange({ productId: e.target.value, productLabel: label, customProductName: e.target.value ? "" : row.customProductName, spareId: "", spareLabel: "", manualSpare: false })
          }}
          className="h-10 w-full rounded-xl border border-border bg-surface px-3 text-sm text-text outline-none"
        >
          <option value="">{t("customerApp.spareEnquiry.selectProductPlaceholder")}</option>
          {categoryProducts.map((p) => (
            <option key={p.id} value={p.id}>
              {[p.name, p.brands?.name, p.models?.name].filter(Boolean).join(" · ")}
            </option>
          ))}
        </select>
      </div>

      {!row.productId ? (
        <div className="space-y-1.5">
          <Label htmlFor={customNameFieldId}>{t("customerApp.spareEnquiry.orTypeProductName")}</Label>
          <Input
            id={customNameFieldId}
            value={row.customProductName}
            onChange={(e) => onChange({ customProductName: e.target.value })}
            placeholder={t("customerApp.spareEnquiry.productNamePlaceholder")}
          />
        </div>
      ) : null}

      {row.productId && hasMappedSpares && !row.manualSpare ? (
        <div className="space-y-1.5">
          <Label htmlFor={spareFieldId}>{t("customerApp.spareEnquiry.selectSpare")}</Label>
          <select
            id={spareFieldId}
            value={row.spareId}
            onChange={(e) => {
              const s = (sparesForProduct ?? []).find((x) => x.id === e.target.value)
              onChange({ spareId: e.target.value, spareLabel: s ? [s.name, s.sku].filter(Boolean).join(" · ") : "" })
            }}
            className="h-10 w-full rounded-xl border border-border bg-surface px-3 text-sm text-text outline-none"
          >
            <option value="">{t("customerApp.spareEnquiry.selectSparePlaceholder")}</option>
            {(sparesForProduct ?? []).map((s) => (
              <option key={s.id} value={s.id}>
                {s.name}
                {s.sku ? ` (${s.sku})` : ""}
              </option>
            ))}
          </select>
          <button type="button" onClick={() => onChange({ manualSpare: true })} className="text-xs font-medium text-accent">
            {t("customerApp.spareEnquiry.cantFindSpare")}
          </button>
        </div>
      ) : row.productId && row.manualSpare ? (
        <button type="button" onClick={() => onChange({ manualSpare: false })} className="text-xs font-medium text-accent">
          {t("customerApp.spareEnquiry.backToSpareList")}
        </button>
      ) : row.productId && !loadingSpares && !hasMappedSpares ? (
        <p className="text-xs text-text-muted">{t("customerApp.spareEnquiry.noMappedSpares")}</p>
      ) : null}
    </div>
  )
}

export function CustomerSpareEnquiryPage() {
  const { t } = useTranslation()
  const navigate = useNavigate()
  const { customerId, orgId, isLoading: loadingId } = useMyCustomerId()
  const { data: products, isLoading, isError, refetch } = useOwnedProducts(orgId)
  const { data: addresses, isLoading: loadingAddresses } = useMyAddresses(customerId)
  const [addressId, setAddressId] = useState("")
  const [addressPickerOpen, setAddressPickerOpen] = useState(false)
  const submitEnquiry = useSubmitEnquiry()

  const [rows, setRows] = useState<SpareEnquiryRowState[]>([emptyRow()])

  function updateRow(id: string, patch: Partial<SpareEnquiryRowState>) {
    setRows((rs) => rs.map((r) => (r.id === id ? { ...r, ...patch } : r)))
  }
  function addRow() {
    setRows((rs) => [...rs, emptyRow()])
  }
  function removeRow(id: string) {
    setRows((rs) => (rs.length > 1 ? rs.filter((r) => r.id !== id) : rs))
  }

  useEffect(() => {
    if (!addressId && addresses && addresses.length > 0) setAddressId(addresses[0].id)
  }, [addresses, addressId])

  const {
    register,
    handleSubmit,
    formState: { errors },
  } = useForm<EnquiryInput>({ resolver: zodResolver(enquirySchema), mode: "onChange", defaultValues: { description: "" } })

  if (loadingId || isLoading || loadingAddresses) return <FullPageLoader label={t("common.loading")} />
  if (isError) {
    return <FullPageError message={t("customerApp.spareEnquiry.loadError")} onRetry={() => refetch()} retryLabel={t("common.retry")} />
  }

  if (submitEnquiry.isSuccess) {
    return (
      <div className="flex min-h-[70vh] items-center justify-center pt-2">
        <Card className="max-w-md items-center gap-3 py-8 text-center lg:px-5">
          <span className="flex size-12 items-center justify-center rounded-full bg-success/15 text-success">
            <CheckCircle2 className="size-6" />
          </span>
          <h1 className="px-1 text-lg font-bold text-text">{t("customerApp.spareEnquiry.submittedTitle")}</h1>
          <p className="px-1 text-sm text-text-muted">{t("customerApp.spareEnquiry.submittedBody")}</p>
          <Button onClick={() => navigate("/customer")}>{t("customerApp.spareEnquiry.backHome")}</Button>
        </Card>
      </div>
    )
  }

  const onSubmit = handleSubmit((values) => {
    if (!orgId) return
    const rowPrefixes = rows
      .map((r) => {
        const label = r.productLabel || r.customProductName
        return [label && `[${label}]`, r.spareLabel && `[Spare: ${r.spareLabel}]`].filter(Boolean).join(" ")
      })
      .filter(Boolean)
    const prefix = rowPrefixes.join(" | ")
    const description = prefix ? `${prefix} ${values.description}` : values.description
    submitEnquiry.mutate({
      orgId,
      kind: "spare",
      enquiryType: null,
      description,
      photoUrl: values.photoUrl,
      addressId: addressId || undefined,
      // Structured items so a "won" lead's quotation can be prefilled with
      // every requested product/spare instead of picked from scratch — see
      // LeadDetailPanel / QuotationFormPage. Rows with only a free-typed
      // product name have no real productId, so they only contribute to the
      // description text above, same as the pre-multi-row behavior.
      items: rows.filter((r) => r.productId).map((r) => ({ productId: r.productId, spareId: r.spareId || undefined, qty: 1 })),
    })
  })

  return (
    <div className="space-y-4 pb-4 pt-2">
      <button type="button" onClick={() => navigate(-1)} className="flex items-center gap-1.5 text-sm font-medium text-text-muted">
        <ArrowLeft className="size-4" />
        {t("customerApp.spareEnquiry.close")}
      </button>
      <h1 className="text-xl font-bold text-text">{t("customerApp.spareEnquiry.title")}</h1>
      <p className="text-sm text-text-muted">{t("customerApp.spareEnquiry.subtitle")}</p>

      <Card className="gap-3 lg:px-5">
        <form onSubmit={onSubmit} className="space-y-5 px-1">
          <div className="space-y-3">
            {rows.map((row) => (
              <SpareEnquiryProductRow
                key={row.id}
                row={row}
                products={products ?? []}
                canRemove={rows.length > 1}
                onChange={(patch) => updateRow(row.id, patch)}
                onRemove={() => removeRow(row.id)}
              />
            ))}
            <Button type="button" size="sm" variant="outline" onClick={addRow}>
              <Plus className="size-3.5" />
              {t("customerApp.spareEnquiry.addAnotherProduct")}
            </Button>
          </div>

          <div className="space-y-1.5">
            <Label>{t("customerApp.bookService.selectAddress")}</Label>
            {(() => {
              const a = (addresses ?? []).find((row) => row.id === addressId)
              return a ? (
                <div className="rounded-xl border border-border bg-surface-alt px-3.5 py-2.5 text-sm">
                  <span className="text-text">{[a.door_no, a.flat_no, a.street_cross, a.area, a.pincode].filter(Boolean).join(", ")}</span>
                  {a.is_primary ? <span className="ml-1.5 text-xs text-accent">{t("customerApp.profile.primary")}</span> : null}
                </div>
              ) : (
                <p className="rounded-xl border border-dashed border-border px-3.5 py-2.5 text-sm text-warning">
                  {t("customerApp.bookService.noAddresses")}
                </p>
              )
            })()}
            <Button type="button" size="sm" variant="outline" onClick={() => setAddressPickerOpen(true)}>
              {t("customerApp.addressPicker.changeAddress")}
            </Button>
          </div>

          <div className="space-y-1.5">
            <Label htmlFor={DESCRIPTION_FIELD_ID}>{t("customerApp.spareEnquiry.partDescription")}</Label>
            <textarea
              id={DESCRIPTION_FIELD_ID}
              rows={3}
              placeholder={t("customerApp.spareEnquiry.partDescriptionPlaceholder")}
              aria-invalid={!!errors.description}
              className="w-full rounded-xl border border-border bg-surface px-3.5 py-2.5 text-sm text-text outline-none placeholder:text-text-muted focus-visible:border-ring focus-visible:ring-3 focus-visible:ring-ring/30"
              {...register("description")}
            />
            {errors.description ? <p className="text-xs text-danger">{t(errors.description.message!)}</p> : null}
            <p className="text-xs text-text-muted">{t("customerApp.spareEnquiry.photoHint")}</p>
          </div>

          {submitEnquiry.isError ? <p className="text-xs text-danger">{(submitEnquiry.error as Error).message}</p> : null}

          <div className="flex justify-end gap-2 pt-1">
            <Button type="button" variant="ghost" size="sm" onClick={() => navigate(-1)}>
              {t("common.cancel")}
            </Button>
            <Button type="submit" size="sm" disabled={submitEnquiry.isPending || !orgId}>
              {submitEnquiry.isPending ? <Loader2 className="size-3.5 animate-spin" /> : t("customerApp.spareEnquiry.submit")}
            </Button>
          </div>
        </form>
      </Card>

      <AddressPickerModal
        open={addressPickerOpen}
        onOpenChange={setAddressPickerOpen}
        orgId={orgId}
        customerId={customerId}
        selectedAddressId={addressId}
        onSelect={(a) => setAddressId(a.id)}
      />
    </div>
  )
}
