import { useState } from "react"
import { useTranslation } from "react-i18next"
import { ExternalLink, Loader2, MapPin, TriangleAlert } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Dialog, DialogBackdrop, DialogContent, DialogDescription, DialogPortal, DialogTitle } from "@/components/ui/dialog"
import { AddressMapPicker } from "@/components/shared/AddressMapPicker"
import { googleMapsPinUrl } from "@/lib/googleMapsLink"
import type { AddressRow } from "@/services/customerApp"

/**
 * "Pin my address" (20261201100000) -- a focused, map-only action, separate from the full
 * add/edit AddressForm (which already requires a pin as part of saving the whole address text).
 * Reuses AddressMapPicker directly rather than duplicating its search/drag/locate UI.
 */
export function AddressPinDialog({
  address,
  open,
  onOpenChange,
  onSave,
  onRemove,
  isSaving,
  isRemoving,
  saveError,
}: {
  address: AddressRow
  open: boolean
  onOpenChange: (open: boolean) => void
  onSave: (coords: { lat: number; lng: number; accuracy?: number }) => void
  onRemove: () => void
  isSaving: boolean
  isRemoving: boolean
  saveError?: string
}) {
  const { t } = useTranslation()
  const [draft, setDraft] = useState<{ lat: number; lng: number; accuracy?: number } | null>(
    address.lat != null && address.lng != null ? { lat: address.lat, lng: address.lng } : null
  )
  const [locateError, setLocateError] = useState<"denied" | "unavailable" | null>(null)

  const hasExistingPin = address.lat != null && address.lng != null

  return (
    <Dialog
      open={open}
      onOpenChange={(next) => {
        if (!next) {
          setDraft(address.lat != null && address.lng != null ? { lat: address.lat, lng: address.lng } : null)
          setLocateError(null)
        }
        onOpenChange(next)
      }}
    >
      <DialogPortal>
        <DialogBackdrop />
        <DialogContent className="max-w-lg">
          <DialogTitle>{t("customerApp.profile.pinDialogTitle")}</DialogTitle>
          <DialogDescription>{t("customerApp.profile.pinDialogHint")}</DialogDescription>

          {locateError ? (
            <p className="flex items-center gap-1.5 rounded-lg bg-warning-soft px-2.5 py-2 text-xs text-warning">
              <TriangleAlert className="size-3.5 shrink-0" />
              {t(locateError === "denied" ? "customerApp.profile.pinLocateDenied" : "customerApp.profile.pinLocateUnavailable")}
            </p>
          ) : null}

          <AddressMapPicker
            lat={draft?.lat}
            lng={draft?.lng}
            onConfirm={(coords) => {
              setLocateError(null)
              setDraft(coords)
            }}
            onLocateError={setLocateError}
          />

          {saveError ? (
            <p className="flex items-center gap-1.5 text-xs text-danger">
              <TriangleAlert className="size-3.5 shrink-0" />
              {saveError}
            </p>
          ) : null}

          <div className="flex items-center justify-between gap-2">
            {hasExistingPin ? (
              <Button type="button" variant="ghost" className="text-danger" disabled={isRemoving || isSaving} onClick={onRemove}>
                {isRemoving ? <Loader2 className="size-3.5 animate-spin" /> : t("customerApp.profile.pinRemove")}
              </Button>
            ) : (
              <span />
            )}
            <div className="flex gap-2">
              <Button type="button" variant="ghost" onClick={() => onOpenChange(false)}>
                {t("common.cancel")}
              </Button>
              <Button type="button" disabled={!draft || isSaving || isRemoving} onClick={() => draft && onSave(draft)}>
                {isSaving ? <Loader2 className="size-3.5 animate-spin" /> : t("common.save")}
              </Button>
            </div>
          </div>
        </DialogContent>
      </DialogPortal>
    </Dialog>
  )
}

/** Small saved-pin preview + "Open in Google Maps" link, shown instead of this dialog once a pin exists. */
export function AddressPinPreview({ lat, lng }: { lat: number; lng: number }) {
  const { t } = useTranslation()
  return (
    <a
      href={googleMapsPinUrl(lat, lng)}
      target="_blank"
      rel="noreferrer"
      className="flex items-center gap-1.5 text-xs font-medium text-accent hover:underline"
    >
      <MapPin className="size-3.5" />
      {t("customerApp.profile.openInMaps")}
      <ExternalLink className="size-3" />
    </a>
  )
}
