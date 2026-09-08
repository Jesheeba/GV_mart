import { supabase } from "@/lib/supabase"
import type { Tables } from "@/types/database"

export type TdsBand = "low" | "medium" | "high"

// BIS IS 10500:2012 desirable/permissible limits (300 / 500 ppm) plus the
// WHO drinking-water TDS classification — see migration
// 20260902100000_water_quality_tds_recommendation.sql for the full source
// citation. Below 300: RO optional (mineralizer preferred, avoid
// over-purifying). 300–500: standard RO. Above 500: RO essential,
// prefer higher-capacity/multi-stage.
export function bandForTds(tdsPpm: number): TdsBand {
  if (tdsPpm < 300) return "low"
  if (tdsPpm <= 500) return "medium"
  return "high"
}

export type CustomerTdsSuggestion = {
  matchedDistrict: string
  typicalTdsPpm: number
  rangeLow: number
  rangeHigh: number
  dataYear: number
  dataSource: string
  sampleCount: number
  isProxy: boolean
  proxyNote: string | null
  band: TdsBand
  products: { id: string; name: string; price: number }[]
  /** Band is High, or the estimate is a lower-confidence proxy — either way a real reading changes the call. */
  recommendWaterTest: boolean
}

/**
 * Resolves a customer's free-text address.district (pincode-lookup-filled,
 * but still free text — real data has casing variants and old district
 * names like "Trichy") against water_quality_reference, falling back to
 * water_quality_district_aliases for genuinely different names. Returns
 * null when the district can't be resolved at all — callers should show
 * nothing rather than guess.
 */
export async function getCustomerTdsSuggestion(orgId: string, rawDistrict: string): Promise<CustomerTdsSuggestion | null> {
  const district = rawDistrict.trim()
  if (!district) return null

  let referenceRow: Tables<"water_quality_reference"> | null = null
  let isProxy = false
  let proxyNote: string | null = null

  const direct = await supabase.from("water_quality_reference").select("*").eq("org_id", orgId).ilike("district", district).maybeSingle()
  if (direct.error) throw direct.error
  referenceRow = direct.data

  if (!referenceRow) {
    const alias = await supabase
      .from("water_quality_district_aliases")
      .select("canonical_district, is_proxy, proxy_note")
      .eq("org_id", orgId)
      .ilike("alias", district)
      .maybeSingle()
    if (alias.error) throw alias.error
    if (alias.data) {
      isProxy = alias.data.is_proxy
      proxyNote = alias.data.proxy_note
      const viaAlias = await supabase
        .from("water_quality_reference")
        .select("*")
        .eq("org_id", orgId)
        .ilike("district", alias.data.canonical_district)
        .maybeSingle()
      if (viaAlias.error) throw viaAlias.error
      referenceRow = viaAlias.data
    }
  }

  if (!referenceRow) return null

  const band = bandForTds(referenceRow.typical_tds_ppm)

  const recs = await supabase
    .from("product_tds_recommendations")
    .select("sort_order, products(id, name, price)")
    .eq("org_id", orgId)
    .eq("band", band)
    .order("sort_order")
  if (recs.error) throw recs.error

  const products = (recs.data ?? [])
    .map((r) => r.products as unknown as { id: string; name: string; price: number } | null)
    .filter((p): p is { id: string; name: string; price: number } => p != null)

  return {
    matchedDistrict: referenceRow.district,
    typicalTdsPpm: referenceRow.typical_tds_ppm,
    rangeLow: referenceRow.tds_range_low,
    rangeHigh: referenceRow.tds_range_high,
    dataYear: referenceRow.data_year,
    dataSource: referenceRow.data_source,
    sampleCount: referenceRow.sample_count,
    isProxy,
    proxyNote,
    band,
    products,
    recommendWaterTest: band === "high" || isProxy,
  }
}
