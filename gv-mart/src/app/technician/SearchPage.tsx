import { useState } from "react"
import { useTranslation } from "react-i18next"
import { Loader2, MapPin, Phone, Search } from "lucide-react"
import { Input } from "@/components/ui/input"
import { Card } from "@/components/ui/card"
import { Button } from "@/components/ui/button"
import { useProfile } from "@/hooks/useProfile"
import { useAddressSearch, useLogCall, useMyTechnician } from "@/hooks/useTechnician"
import { JobTypeBadge } from "./components/JobBadges"

const OPEN_STATUSES = new Set(["open", "assigned", "in_progress"])

function googleMapsUrl(lat: number, lng: number) {
  return `https://www.google.com/maps/dir/?api=1&destination=${lat},${lng}`
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
                    <a href={googleMapsUrl(addr.lat, addr.lng)} target="_blank" rel="noreferrer" className="flex-1">
                      <Button type="button" variant="outline" className="w-full">
                        <MapPin className="size-3.5" />
                        {t("technician.search.navigate")}
                      </Button>
                    </a>
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
