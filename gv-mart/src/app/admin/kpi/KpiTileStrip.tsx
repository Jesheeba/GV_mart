import { useEffect, useMemo, useState } from "react"
import { useTranslation } from "react-i18next"
import { ChevronDown, CircleHelp, TriangleAlert } from "lucide-react"
import { Popover, PopoverContent, PopoverTrigger } from "@/components/ui/popover"
import { Skeleton } from "@/components/ui/skeleton"
import { cn } from "@/lib/utils"
import { formatCurrency } from "@/lib/sale-calc"
import { useKpiTiles } from "@/hooks/useKpiTiles"
import type { DateRange } from "@/services/reports"
import {
  buildKpiView,
  formatKpiValue,
  pickTiles,
  type KpiGroup,
  type KpiStreamsView,
  type KpiText,
  type KpiTileId,
  type KpiTileView,
} from "./kpiTilesView"

const CARD =
  "rounded-card border border-border bg-surface shadow-[0_1px_2px_rgba(26,26,26,.04),0_14px_30px_-22px_rgba(26,26,26,.16)]"

/** matchMedia-backed "phone width" flag (below Tailwind's sm, 640 px). Safe when matchMedia is missing. */
function useIsNarrow() {
  const query = "(max-width: 639px)"
  const [narrow, setNarrow] = useState(() => (typeof window !== "undefined" && window.matchMedia ? window.matchMedia(query).matches : false))
  useEffect(() => {
    if (typeof window === "undefined" || !window.matchMedia) return
    const mq = window.matchMedia(query)
    const on = () => setNarrow(mq.matches)
    on()
    mq.addEventListener("change", on)
    return () => mq.removeEventListener("change", on)
  }, [])
  return narrow
}

function shortDate(iso: string, lang: string) {
  const d = new Date(`${iso}T00:00:00`)
  if (Number.isNaN(d.getTime())) return iso
  return d.toLocaleDateString(lang.startsWith("ta") ? "ta-IN" : "en-IN", { day: "numeric", month: "short" })
}

function HelpButton({ title, body, exact }: { title: string; body: string; exact?: string }) {
  const { t } = useTranslation()
  return (
    <Popover>
      <PopoverTrigger
        aria-label={`${t("kpi.helpButton")} ${title}`}
        className="flex size-8 shrink-0 items-center justify-center rounded-full text-text-muted transition-colors hover:bg-surface-alt focus-visible:outline-2 focus-visible:outline-ring sm:size-6"
        data-testid="kpi-help"
      >
        <CircleHelp className="size-4" />
      </PopoverTrigger>
      <PopoverContent className="max-w-[min(20rem,85vw)] space-y-2 text-sm">
        <p className="font-semibold text-text">{title}</p>
        <p className="text-text-muted">{body}</p>
        {exact ? <p className="text-xs font-semibold tabular-nums text-text">{exact}</p> : null}
      </PopoverContent>
    </Popover>
  )
}

function KpiTile({ tile, accent, compact }: { tile: KpiTileView; accent?: boolean; compact: boolean }) {
  const { t } = useTranslation()
  const tr = (x: KpiText) => t(x.key, x.params)
  const title = t(tile.titleKey)
  const exact = tile.value.kind === "currency" && tile.value.amount != null ? t("kpi.exactAmount", { amount: formatCurrency(tile.value.amount) }) : undefined
  return (
    <div
      data-testid={`kpi-tile-${tile.id}`}
      className={cn(
        "relative flex min-w-0 flex-col gap-3 overflow-hidden p-4 sm:p-5",
        accent ? "rounded-card bg-gradient-to-br from-accent to-[#FF7E47] text-white shadow-[0_14px_32px_-16px_rgba(245,97,44,0.65)]" : CARD,
        tile.empty && !accent && "opacity-90"
      )}
    >
      <div className="flex items-start justify-between gap-2">
        <span className={cn("min-w-0 text-[13px] font-semibold leading-snug", accent ? "text-white/90" : "text-text-muted")}>{title}</span>
        <div className={cn("-mr-1.5 -mt-1.5 flex items-center gap-1", accent && "[&_button]:text-white/90 [&_button:hover]:bg-white/20")}>
          <HelpButton title={title} body={t(tile.helpKey)} exact={exact} />
        </div>
      </div>
      <div data-testid="kpi-value" className={cn("whitespace-nowrap text-[26px] font-extrabold leading-none tracking-tight tabular-nums sm:text-[31px]", accent ? "text-white" : "text-text")}>
        {formatKpiValue(tile.value, { compact })}
      </div>
      {tile.sub || tile.live ? (
        <div className="flex flex-wrap items-center gap-x-2 gap-y-1">
          {tile.live ? (
            <span data-testid="kpi-live" className={cn("rounded-full px-2 py-0.5 text-[10px] font-bold uppercase tracking-wide", accent ? "bg-white/25" : "bg-info/10 text-info")}>
              {t("kpi.live")}
            </span>
          ) : null}
          {tile.sub ? <span className={cn("text-xs font-semibold leading-snug", accent ? "text-white/90" : "text-text-muted")}>{tr(tile.sub)}</span> : null}
        </div>
      ) : null}
      {tile.badge ? (
        <span
          data-testid="kpi-cost-missing"
          className="flex w-fit items-start gap-1.5 rounded-full bg-warning/10 px-2.5 py-1 text-xs font-bold leading-snug text-warning"
        >
          <TriangleAlert className="mt-px size-3.5 shrink-0" />
          {tr(tile.badge)}
        </span>
      ) : null}
    </div>
  )
}

function StreamsTile({ streams, compact }: { streams: KpiStreamsView; compact: boolean }) {
  const { t } = useTranslation()
  const title = t(streams.titleKey)
  return (
    <div data-testid="kpi-tile-streams" className={cn(CARD, "col-span-full flex flex-col gap-3 p-4 sm:p-5")}>
      <div className="flex items-start justify-between gap-2">
        <span className="text-[13px] font-semibold text-text-muted">{title}</span>
        <div className="-mr-1.5 -mt-1.5">
          <HelpButton title={title} body={t(streams.helpKey)} exact={t("kpi.exactAmount", { amount: formatCurrency(streams.total) })} />
        </div>
      </div>
      <div className="flex flex-col gap-2">
        {streams.rows.map((r) => (
          <div key={r.id} data-testid={`kpi-stream-${r.id}`} className="flex flex-col gap-1">
            <div className="flex items-baseline justify-between gap-3 text-sm">
              <span className="min-w-0 font-medium text-text">{t(r.labelKey)}</span>
              <span className="shrink-0 font-bold tabular-nums text-text">
                {formatKpiValue({ kind: "currency", amount: r.amount }, { compact })} <span className="text-xs font-semibold text-text-muted">{r.percent}%</span>
              </span>
            </div>
            <div className="h-1.5 overflow-hidden rounded-full bg-[#F0EBE3]">
              <div className="h-full rounded-full bg-accent" style={{ width: `${Math.min(100, r.percent)}%` }} />
            </div>
          </div>
        ))}
      </div>
      <div className="flex items-baseline justify-between gap-3 border-t border-border pt-2 text-sm">
        <span className="font-semibold text-text-muted">{t(streams.totalKey)}</span>
        <span className="font-extrabold tabular-nums text-text">{formatKpiValue({ kind: "currency", amount: streams.total }, { compact })}</span>
      </div>
      <p className="text-xs font-medium text-text-muted" data-testid="kpi-streams-note">
        {t(streams.noteKey)}
      </p>
    </div>
  )
}

function StripSkeleton({ headline }: { headline: number }) {
  return (
    <div data-testid="kpi-skeleton" className="space-y-4.5" aria-busy="true">
      <div className="grid grid-cols-1 gap-3 min-[480px]:grid-cols-2 sm:gap-4.5 lg:grid-cols-3">
        {Array.from({ length: headline }).map((_, i) => (
          <div key={i} className={cn(CARD, "flex flex-col gap-3 p-4 sm:p-5")}>
            <Skeleton className="h-4 w-24" />
            <Skeleton className="h-8 w-28" />
            <Skeleton className="h-3 w-20" />
          </div>
        ))}
      </div>
    </div>
  )
}

/**
 * One consistent snapshot from `report_kpi_tiles`.
 *  - dashboard mode (no `only`): six headline tiles, then one collapsible section per group the server returned;
 *  - reports mode (`only`): a flat strip of just those tiles, for the tab it sits on.
 * A group the role may not see is absent from the payload and therefore simply not rendered.
 */
export function KpiTileStrip({ range, only, className }: { range: DateRange; only?: (KpiTileId | "streams")[]; className?: string }) {
  const { t, i18n } = useTranslation()
  const { data, isLoading, isError, isFetching, refetch } = useKpiTiles(range)
  const narrow = useIsNarrow()
  const view = useMemo(() => (data ? buildKpiView(data) : null), [data])
  const [collapsed, setCollapsed] = useState<Partial<Record<KpiGroup, boolean>>>({})

  const periodLabel = t("kpi.period", { from: shortDate(range.from, i18n.language), to: shortDate(range.to, i18n.language) })

  if (isLoading && !view) return <StripSkeleton headline={only ? Math.min(only.length, 4) : 6} />

  if (isError && !view) {
    return (
      <div data-testid="kpi-error" className={cn(CARD, "flex flex-wrap items-center justify-between gap-3 p-4 sm:p-5", className)} role="alert">
        <div className="flex items-center gap-2 text-sm font-semibold text-danger">
          <TriangleAlert className="size-4 shrink-0" />
          {t("kpi.error")}
        </div>
        <button
          type="button"
          onClick={() => refetch()}
          className="min-h-11 rounded-full border border-border bg-surface px-4 text-sm font-bold text-text sm:min-h-9"
          data-testid="kpi-retry"
        >
          {t("common.retry")}
        </button>
      </div>
    )
  }
  if (!view) return null

  const footer = (
    <p data-testid="kpi-period" className="flex items-center gap-2 text-xs font-medium text-text-muted">
      {periodLabel}
      {isFetching ? <span className="font-semibold">{t("kpi.updating")}</span> : null}
    </p>
  )

  if (only) {
    const picked = pickTiles(view, only)
    if (picked.tiles.length === 0 && !picked.streams) return null
    return (
      <div data-testid="kpi-strip" className={cn("space-y-2", className)}>
        <div className="grid grid-cols-1 gap-3 min-[480px]:grid-cols-2 sm:gap-4.5 lg:grid-cols-4">
          {picked.tiles.map((tile) => (
            <KpiTile key={tile.id} tile={tile} compact={narrow} />
          ))}
          {picked.streams ? <StreamsTile streams={picked.streams} compact={narrow} /> : null}
        </div>
        {footer}
      </div>
    )
  }

  return (
    <div data-testid="kpi-strip" className={cn("space-y-4.5", className)}>
      <div className="grid grid-cols-1 gap-3 min-[480px]:grid-cols-2 sm:gap-4.5 lg:grid-cols-3">
        {view.headline.map((tile, i) => (
          <KpiTile key={tile.id} tile={tile} accent={i === 0} compact={narrow} />
        ))}
      </div>
      {view.groups.map((g, gi) => {
        // phone: first section open, the rest collapsed; from sm up every section is always open
        const isCollapsed = collapsed[g.group] ?? gi > 0
        const showStreams = g.group === "sales" && view.streams
        return (
          <section key={g.group} data-testid={`kpi-group-${g.group}`}>
            <button
              type="button"
              onClick={() => setCollapsed((c) => ({ ...c, [g.group]: !isCollapsed }))}
              aria-expanded={!isCollapsed}
              aria-label={t("kpi.toggleGroup", { group: t(g.titleKey) })}
              className="mb-2 flex min-h-11 w-full items-center justify-between text-left sm:pointer-events-none sm:min-h-0"
            >
              <h3 className="text-[15px] font-bold tracking-tight text-text">{t(g.titleKey)}</h3>
              <ChevronDown className={cn("size-4 text-text-muted transition-transform sm:hidden", !isCollapsed && "rotate-180")} />
            </button>
            <div className={cn("grid-cols-1 gap-3 min-[480px]:grid-cols-2 sm:gap-4.5 lg:grid-cols-4", isCollapsed ? "hidden sm:grid" : "grid")}>
              {g.tiles.map((tile) => (
                <KpiTile key={tile.id} tile={tile} compact={narrow} />
              ))}
              {showStreams ? <StreamsTile streams={view.streams!} compact={narrow} /> : null}
            </div>
          </section>
        )
      })}
      {footer}
    </div>
  )
}
