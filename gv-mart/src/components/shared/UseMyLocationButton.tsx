import { Loader2, LocateFixed } from "lucide-react"
import { Button } from "@/components/ui/button"

/**
 * Customer-side discoverability fix: the map widget's own corner "locate" control
 * (MapControls, components/ui/map.tsx) is icon-only with no visible label -- easy to miss,
 * especially on a phone with no hover tooltip. This is the same action, labelled, full width,
 * and a proper >=44px touch target, placed directly above the map in every customer-app
 * address surface (AddressMapPicker). Pure/presentational -- no geolocation logic of its own,
 * so it renders (and is testable) with no network/browser-API dependency at all.
 */
export function UseMyLocationButton({ locating, label, locatingLabel, onClick }: { locating: boolean; label: string; locatingLabel: string; onClick: () => void }) {
  return (
    <Button type="button" variant="outline" className="h-11 w-full justify-center gap-2" onClick={onClick} disabled={locating}>
      {locating ? <Loader2 className="size-4 animate-spin" /> : <LocateFixed className="size-4" />}
      {locating ? locatingLabel : label}
    </Button>
  )
}
