import type { Enums } from "@/types/database"

export type LeadSummaryTileId = "total" | "new" | "contacted" | "quoted" | "won" | "lost"

export interface LeadSummaryTile {
  id: LeadSummaryTileId
  count: number
  pct: number
}

const STATUS_TILE_IDS: Exclude<LeadSummaryTileId, "total">[] = ["new", "contacted", "quoted", "won", "lost"]

/** Count + percentage (of the given list) for Total and each lead_status, in the order the spec requires. */
export function computeLeadSummaryTiles(rows: { status: Enums<"lead_status"> }[]): LeadSummaryTile[] {
  const total = rows.length
  const pct = (count: number) => (total > 0 ? Math.round((count / total) * 100) : 0)
  const totalTile: LeadSummaryTile = { id: "total", count: total, pct: total > 0 ? 100 : 0 }
  const statusTiles = STATUS_TILE_IDS.map((id) => {
    const count = rows.filter((r) => r.status === id).length
    return { id, count, pct: pct(count) }
  })
  return [totalTile, ...statusTiles]
}
