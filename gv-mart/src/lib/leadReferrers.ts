/** Row shape of the extra read Daily Follow Up does for the leads on screen. */
export type LeadOwnerRow = {
  id: string
  owner_id: string | null
  technicians: { profiles: { full_name: string | null } | null } | null
}

/** lead id -> owning/referring technician's name. Leads with no technician (or no name) are left out. */
export function buildLeadTechnicianNames(rows: LeadOwnerRow[]): Map<string, string> {
  const out = new Map<string, string>()
  for (const r of rows) {
    const name = r.technicians?.profiles?.full_name?.trim()
    if (r.owner_id && name) out.set(r.id, name)
  }
  return out
}

/** Chunk size for the `id in (...)` read, keeps the request URL short. */
export const LEAD_OWNER_CHUNK = 100

export function chunk<T>(items: T[], size: number): T[][] {
  const out: T[][] = []
  for (let i = 0; i < items.length; i += size) out.push(items.slice(i, i + size))
  return out
}
