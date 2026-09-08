/**
 * One-time (then annual) import of CGWB groundwater TDS data into
 * water_quality_reference. NOT run automatically and NOT called live from
 * the app — the government portal only publishes periodic bulk files, and
 * the TDS-based RO recommendation feature is explicitly a static local
 * lookup, never a live query against nwdp.nwic.gov.in.
 *
 * Source: National Water Data Portal (nwdp.nwic.gov.in), CGWB "Ground
 * Water Quality Manual Chemical Parameters" dataset — download the state's
 * CSV from the dataset page (e.g. the Tamil Nadu resource under
 * https://nwdp.nwic.gov.in/dataset/ground-water-quality-manual-chemical-parameters-cgwb-f-gfg)
 * and pass its path as the first argument. Re-run when a new year's file
 * is published (CGWB updates roughly annually).
 *
 * Requires SUPABASE_URL + SUPABASE_SERVICE_ROLE_KEY (same as npm run seed).
 * Run: tsx scripts/import-water-quality.ts <path-to-cgwb-chemical-parameters-csv> <org-id>
 */
import { createClient } from "@supabase/supabase-js"
import { readFileSync } from "node:fs"
import type { Database } from "../src/types/database"

const SUPABASE_URL = process.env.SUPABASE_URL
const SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY
const [csvPath, orgId] = process.argv.slice(2)

if (!SUPABASE_URL || !SERVICE_ROLE_KEY) {
  console.error("Missing SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY env vars.")
  process.exit(1)
}
if (!csvPath || !orgId) {
  console.error("Usage: tsx scripts/import-water-quality.ts <path-to-cgwb-chemical-parameters-csv> <org-id>")
  process.exit(1)
}

const supabase = createClient<Database>(SUPABASE_URL, SERVICE_ROLE_KEY, {
  auth: { autoRefreshToken: false, persistSession: false },
})

// The CGWB "Chemical Parameters" CSV has District at column 6 and
// "Total Dissolved Solids (mg/L)" at column 21 — confirmed against the
// real Tamil Nadu file (gwq_chemical_parameter_manual_cgwb_tn_1961_2025.csv).
// Other states' files from the same dataset share this column layout.
const DISTRICT_COL = 6
const DATE_COL = 18
const TDS_COL = 21

// The source data itself has a spelling duplicate for this district.
const DISTRICT_ALIASES: Record<string, string> = {
  Thiruvannamalai: "Tiruvannamalai",
}

function median(values: number[]): number {
  const sorted = [...values].sort((a, b) => a - b)
  const mid = Math.floor(sorted.length / 2)
  return sorted.length % 2 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2
}

const lines = readFileSync(csvPath, "utf8").split("\n").filter(Boolean)
const byDistrict = new Map<string, { tds: number; year: number | null }[]>()

for (let i = 1; i < lines.length; i++) {
  const parts = lines[i].split(",")
  if (parts.length <= TDS_COL) continue

  let district = parts[DISTRICT_COL]?.trim()
  if (!district) continue
  district = DISTRICT_ALIASES[district] ?? district

  const tdsRaw = parts[TDS_COL]?.replace(/"/g, "").trim()
  const tds = tdsRaw ? Number.parseFloat(tdsRaw) : NaN
  if (!Number.isFinite(tds) || tds <= 0 || tds > 20000) continue // sanity filter — excludes blanks and obvious data-entry errors

  const yearMatch = parts[DATE_COL]?.match(/(\d{4})/)
  const year = yearMatch ? Number.parseInt(yearMatch[1], 10) : null

  if (!byDistrict.has(district)) byDistrict.set(district, [])
  byDistrict.get(district)!.push({ tds, year })
}

const rows = [...byDistrict.entries()].map(([district, readings]) => {
  const tdsValues = readings.map((r) => r.tds)
  const years = readings.map((r) => r.year).filter((y): y is number => y != null)
  return {
    org_id: orgId,
    district,
    typical_tds_ppm: Math.round(median(tdsValues) * 10) / 10,
    tds_range_low: Math.round(Math.min(...tdsValues) * 10) / 10,
    tds_range_high: Math.round(Math.max(...tdsValues) * 10) / 10,
    sample_count: readings.length,
    data_year: years.length ? Math.max(...years) : new Date().getFullYear(),
    updated_at: new Date().toISOString(),
  }
})

console.log(`Parsed ${rows.length} districts with usable TDS readings from ${csvPath}.`)

const { error } = await supabase.from("water_quality_reference").upsert(rows, { onConflict: "org_id,district" })
if (error) {
  console.error("Upsert failed:", error)
  process.exit(1)
}
console.log(`Upserted ${rows.length} water_quality_reference rows for org ${orgId}.`)
