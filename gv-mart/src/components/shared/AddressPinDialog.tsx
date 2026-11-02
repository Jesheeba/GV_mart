import { useState } from "react"
import { useTranslation } from "react-i18next"
import { ExternalLink, Loader2, MapPin, TriangleAlert } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { Dialog, DialogBackdrop, DialogContent, DialogDescription, DialogPortal, DialogTitle } from "@/components/ui/dialog"
import { AddressMapPicker } from "@/components/shared/AddressMapPicker"
import { googleMapsPinUrl } from "@/lib/googleMapsLink"
import { useReverseGeocode } from "@/hooks/useMaps"
import { isTooManyRequestsError } from "@/services/maps"
import { geocodeResultToAddressFields, mergeAddressFieldsPreservingTyped, type AddressTextFields } from "@/lib/geocodeToAddressFields"
import type { AddressRow, AddressTextFieldsPatch } from "@/services/customerApp"

const FIELD_LABEL_KEYS: Record<keyof AddressTextFields, string> = {
  doorNo: "customerApp.profile.address.doorNo",
  streetCross: "customerApp.profile.address.streetCross",
  area: "customerApp.profile.address.area",
  pincode: "customerApp.profile.address.pincode",
  district: "customerApp.profile.address.district",
  state: "customerApp.profile.address.state",
}

function toFieldsPatch(fields: AddressTextFields): AddressTextFieldsPatch {
  const patch: AddressTextFieldsPatch = {}
  if (fields.doorNo) patch.door_no = fields.doorNo
  if (fields.streetCross) patch.street_cross = fields.streetCross
  if (fields.area) patch.area = fields.area
  if (fields.pincode) patch.pincode = fields.pincode
  if (fields.district) patch.district = fields.district
  if (fields.state) patch.state = fields.state
  return patch
}

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
  onSave: (coords: { lat: number; lng: number; accuracy?: number; fields?: AddressTextFieldsPatch }) => void
  onRemove: () => void
  isSaving: boolean
  isRemoving: boolean
  saveError?: string
}) {
  const { t } = useTranslation()
  const [draft, setDraft] = useState<{ lat: number; lng: number; accuracy?: number } | null>(
    address.lat != null && address.lng != null ? { lat: address.lat, lng: address.lng } : null
  )
  const [locateError, setLocateError] = useState<"denied" | "unavailable" | "timeout" | null>(null)

  // "Use my current location" -> address text. Only offered for a drag-confirm or a geolocation
  // confirm (source !== "search" -- this dialog has no search box of its own, but AddressMapPicker
  // is shared, so the same tag applies). Only ever proposes fields that are currently empty on
  // THIS address -- never silently overwrites text already saved on it. Edited here, not applied,
  // until Save; Cancel/close discards it, same as the pin itself.
  const reverseGeocode = useReverseGeocode()
  const [fieldsPatch, setFieldsPatch] = useState<AddressTextFields | null>(null)
  const [locationLookupFailed, setLocationLookupFailed] = useState(false)
  const [locationRateLimited, setLocationRateLimited] = useState(false)

  function handleConfirm(coords: { lat: number; lng: number; accuracy?: number; source: "search" | "drag" | "location" }) {
    setLocateError(null)
    setDraft(coords)
    setLocationLookupFailed(false)
    setLocationRateLimited(false)
    if (coords.source === "search") return
    reverseGeocode.mutate(
      { lat: coords.lat, lng: coords.lng },
      {
        onSuccess: (result) => {
          const derived = geocodeResultToAddressFields(result)
          const current: AddressTextFields = {
            doorNo: address.door_no ?? undefined,
            streetCross: address.street_cross ?? undefined,
            area: address.area ?? undefined,
            pincode: address.pincode ?? undefined,
            district: address.district ?? undefined,
            state: address.state ?? undefined,
          }
          const patch = mergeAddressFieldsPreservingTyped(current, derived)
          setFieldsPatch(Object.keys(patch).length > 0 ? patch : null)
        },
        onError: (err) => (isTooManyRequestsError(err) ? setLocationRateLimited(true) : setLocationLookupFailed(true)),
      }
    )
  }

  const hasExistingPin = address.lat != null && address.lng != null

  return (
    <Dialog
      open={open}
      onOpenChange={(next) => {
        if (!next) {
          setDraft(address.lat != null && address.lng != null ? { lat: address.lat, lng: address.lng } : null)
          setLocateError(null)
          setFieldsPatch(null)
          setLocationLookupFailed(false)
          setLocationRateLimited(false)
        }
        onOpenChange(next)
      }}
    >
      <DialogPortal>
        <DialogBackdrop />
        <DialogContent className="max-w-lg">
          <DialogTitle>{t("customerApp.profile.pinDialogTitle")}</DialogTitle>
          <DialogDescription>{t("customerApp.profile.pinDialogHint")}</DialogDescription>
          <p className="text-xs text-text-muted">{t("customerApp.profile.address.locationPrivacyNotice")}</p>

          {locateError ? (
            <p className="flex items-center gap-1.5 rounded-lg bg-warning-soft px-2.5 py-2 text-xs text-warning">
              <TriangleAlert className="size-3.5 shrink-0" />
              {t(
                locateError === "denied"
                  ? "customerApp.profile.pinLocateDenied"
                  : locateError === "timeout"
                    ? "customerApp.profile.pinLocateTimeout"
                    : "customerApp.profile.pinLocateUnavailable"
              )}
            </p>
          ) : null}

          <AddressMapPicker lat={draft?.lat} lng={draft?.lng} onConfirm={handleConfirm} onLocateError={setLocateError} />

          {reverseGeocode.isPending ? (
            <p className="flex items-center gap-1.5 text-xs text-text-muted">
              <Loader2 className="size-3 animate-spin" />
              {t("customerApp.profile.pinLocationLookingUp")}
            </p>
          ) : null}
          {locationLookupFailed ? <p className="text-xs text-text-muted">{t("customerApp.profile.pinLocationLookupFailed")}</p> : null}
          {locationRateLimited ? <p className="text-xs text-warning">{t("customerApp.profile.address.tooManyRequests")}</p> : null}

          {fieldsPatch ? (
            <div className="space-y-2 rounded-xl bg-surface-alt px-3 py-2.5">
              <p className="text-xs font-medium text-success">{t("customerApp.profile.pinLocationFilledNotice")}</p>
              <div className="grid grid-cols-2 gap-2">
                {(Object.keys(fieldsPatch) as (keyof AddressTextFields)[]).map((key) => (
                  <div key={key} className="space-y-1">
                    <Label htmlFor={`pin-field-${key}`} className="text-xs text-text-muted">
                      {t(FIELD_LABEL_KEYS[key])}
                    </Label>
                    <Input
                      id={`pin-field-${key}`}
                      value={fieldsPatch[key] ?? ""}
                      onChange={(e) => setFieldsPatch({ ...fieldsPatch, [key]: e.target.value })}
                    />
                  </div>
                ))}
              </div>
            </div>
          ) : null}

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
              <Button
                type="button"
                disabled={!draft || isSaving || isRemoving}
                onClick={() => draft && onSave({ ...draft, fields: fieldsPatch ? toFieldsPatch(fieldsPatch) : undefined })}
              >
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
