/**
 * Quotations dashboard KPIs (2026-11-27). Each status count also carries its
 * share of all quotations (the % in the card corner); conversion rate is
 * converted / (converted + lost), i.e. of the quotes that have been decided.
 */
export function quotationStats(rows: { status: string }[]) {
  const count = (s: string) => rows.filter((r) => r.status === s).length
  const total = rows.length
  const share = (n: number) => (total > 0 ? Math.round((n / total) * 100) : 0)
  const open = count("open")
  const converted = count("converted")
  const lost = count("lost")
  const decided = converted + lost
  return {
    open,
    converted,
    lost,
    openPct: share(open),
    convertedPct: share(converted),
    lostPct: share(lost),
    decided,
    rate: decided > 0 ? Math.round((converted / decided) * 100) : 0,
  }
}
