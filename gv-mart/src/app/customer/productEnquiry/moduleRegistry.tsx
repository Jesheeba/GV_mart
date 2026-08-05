import { CallbackCta } from "./CallbackCta"
import { CustomerCatalogGrid } from "./CustomerCatalogGrid"
import { QuotationCta } from "./QuotationCta"
import { ShareCta } from "./ShareCta"
import { VideoLibraryTabContent } from "./VideoLibraryTabContent"
import type { Enums, Json, Tables } from "@/types/database"

export type TabRendererProps = { orgId: string | undefined; tab: Tables<"product_enquiry_tabs"> }

export type CtaRendererProps = {
  orgId: string | undefined
  productId: string
  cta: Tables<"product_enquiry_cta_config">
  product: { name: string; price: number; brandName: string | null }
  emiPerMonth: number | null
}

function toStringArray(json: Json | null | undefined): string[] {
  return Array.isArray(json) ? json.filter((x): x is string => typeof x === "string") : []
}

/**
 * Product Enquiry rebuild (2026-08-04) — the module-type -> component
 * lookup that IS the "new module type needs a code change" boundary
 * (§ explicit call-out in the plan): TypeScript's exhaustive-record-lookup
 * means adding a new `product_enquiry_tab_type` enum value without adding
 * an entry here fails to compile. Deliberately a plain object, not a
 * dynamic import/plugin system — boring and explicit, matching this
 * codebase's style everywhere else.
 */
export const TAB_RENDERERS: Record<Enums<"product_enquiry_tab_type">, (props: TabRendererProps) => React.ReactNode> = {
  catalog_grid: ({ orgId }) => <CustomerCatalogGrid orgId={orgId} />,
  video_library: ({ orgId, tab }) => (
    <VideoLibraryTabContent orgId={orgId} topics={toStringArray((tab.config as Record<string, Json>)?.topics) as Enums<"enquiry_type">[]} />
  ),
}

export const CTA_RENDERERS: Record<Enums<"product_enquiry_cta_type">, (props: CtaRendererProps) => React.ReactNode> = {
  quotation: ({ orgId, productId, cta }) => <QuotationCta key={cta.id} orgId={orgId} productId={productId} config={cta.config} label={cta.label} />,
  callback: ({ productId, cta }) => <CallbackCta key={cta.id} productId={productId} label={cta.label} />,
  share: ({ cta, product, emiPerMonth }) => <ShareCta key={cta.id} config={cta.config} name={product.name} brand={product.brandName} price={product.price} emiPerMonth={emiPerMonth} />,
}
