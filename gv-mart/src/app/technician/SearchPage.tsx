import { useState } from "react"
import { useTranslation } from "react-i18next"
import { Loader2, MapPin, Phone, Search } from "lucide-react"
import { Input } from "@/components/ui/input"
import { Card } from "@/components/ui/card"
import { Button } from "@/components/ui/button"
import { useProfile } from "@/hooks/useProfile"
import { useAddressSearch, useLogCall, useMyTechnician } from "@/hooks/useTechnician"
import { getCurrentPosition } from "@/lib/offline/geo"
import { JobTypeBadge } from "./components/JobBadges"

const OPEN_STATUSES = new Set(["open", "assigned", "in_progress"])

function googleMapsUrl(lat: number, lng: number, origin?: { lat: number; lng: number } | null) {
  const params = new URLSearchParams({ api: "1", destination: `${lat},${lng}` })
  if (origin) params.set("origin", `${origin.lat},${origin.lng}`)
  return `https://www.google.com/maps/dir/?${params.toString()}`
}

// This screen (unlike MapPage) doesn't keep a live GPS watch running, so
// there's no already-tracked position to hand Google Maps as `origin=` —
// without one, Maps resolves "Your location" itself on open, which can use
// a stale/cached browser fix instead of where the technician actually is.
// Grabbing a fresh one-shot fix here and threading it through as an
// explicit origin avoids that. The tab is opened synchronously (before the
// `await`) so it stays tied to the click gesture and isn't popup-blocked;
// it's then pointed at the resolved URL once the fix (or the timeout/denial
// fallback) resolves.
async function openNavigation(lat: number, lng: number) {
  const win = window.open("", "_blank")
  try {
    const origin = await getCurrentPosition()
    if (win) win.location.href = googleMapsUrl(lat, lng, origin)
  } catch {
    if (win) win.location.href = googleMapsUrl(lat, lng)
  }
}

export function SearchPage() {
  const { t } = useTranslation()
  const { data: profile } = useProfile()
  const [term, setTerm] = useState("")
  const results = useAddressSearch(profile?.org_id, term)
  const technician = useMyTechnician()
  const logCall = useLogCall()

  return (
    <div className="space-y-4 pt-2">
      <h1 className="text-xl font-bold text-text">{t("technician.search.title")}</h1>

      <div className="relative">
        <Search className="pointer-events-none absolute left-3.5 top-1/2 size-4 -translate-y-1/2 text-text-muted" />
        <Input
          value={term}
          onChange={(e) => setTerm(e.target.value)}
          placeholder={t("technician.search.placeholder")}
          aria-label={t("technician.search.title")}
          className="pl-10"
        />
      </div>

      {term.trim().length <= 1 ? (
        <Card className="items-center gap-1 py-8 text-center">
          <p className="text-sm text-text-muted">{t("technician.search.hint")}</p>
        </Card>
      ) : results.isLoading || results.isFetching ? (
        <Card className="items-center gap-2 py-8 text-center">
          <Loader2 className="size-5 animate-spin text-text-muted" />
        </Card>
      ) : results.isError ? (
        <Card className="items-center gap-1 py-8 text-center">
          <p className="text-sm text-danger">{t("technician.errors.loadFailed")}</p>
        </Card>
      ) : !results.data || results.data.length === 0 ? (
        <Card className="items-center gap-1 py-8 text-center">
          <p className="text-sm text-text-muted">{t("technician.search.empty")}</p>
        </Card>
      ) : (
        <div className="space-y-2.5">
          {results.data.map((addr) => {
            const customer = addr.customers
            const addressLine = [addr.door_no, addr.area, addr.pincode].filter(Boolean).join(", ")
            const relevantJob = customer?.service_tickets
              ?.filter((tk) => OPEN_STATUSES.has(tk.status))
              .sort((a, b) => (a.created_at < b.created_at ? 1 : -1))[0]
            return (
              <Card key={addr.id} className="gap-2.5">
                <div>
                  <p className="px-1 text-sm font-semibold text-text">{customer?.name ?? t("technician.home.unknownCustomer")}</p>
                  <p className="flex items-center gap-1 px-1 text-xs text-text-muted">
                    <MapPin className="size-3 shrink-0" /> <span className="truncate">{addressLine || "—"}</span>
                  </p>
                </div>
                {relevantJob ? (
                  <div className="flex flex-wrap items-center gap-1.5 px-1">
                    <JobTypeBadge type={relevantJob.type} />
                    <span className="text-xs text-text-muted">{relevantJob.products?.name ?? relevantJob.name_of_complaint ?? "—"}</span>
                  </div>
                ) : null}
                <div className="flex gap-2 px-1">
                  {customer?.mobile ? (
                    <a
                      href={`tel:${customer.mobile}`}
                      className="flex-1"
                      onClick={() =>
                        logCall.mutate({ orgId: profile!.org_id, technicianId: technician.data?.id ?? null, customerId: customer.id, ticketId: relevantJob?.id ?? null })
                      }
                    >
                      <Button type="button" variant="outline" className="w-full">
                        <Phone className="size-3.5" />
                        {t("technician.search.call")}
                      </Button>
                    </a>
                  ) : null}
                  {addr.lat != null && addr.lng != null ? (
                    <Button type="button" variant="outline" className="w-full flex-1" onClick={() => void openNavigation(addr.lat!, addr.lng!)}>
                      <MapPin className="size-3.5" />
                      {t("technician.search.navigate")}
                    </Button>
                  ) : null}
                </div>
              </Card>
            )
          })}
        </div>
      )}
    </div>
  )
}
