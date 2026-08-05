import { useEffect, useId, useRef, useState } from "react"
import { useTranslation } from "react-i18next"
import { zodResolver } from "@hookform/resolvers/zod"
import { useForm } from "react-hook-form"
import { Loader2 } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { AddressMapPicker } from "@/components/shared/AddressMapPicker"
import { useDebouncedValue } from "@/hooks/useDebouncedValue"
import { useGeocodeAddress } from "@/hooks/useMaps"
import { isPreciseGeocodeResult } from "@/services/maps"
import { customerAddressSchema, type CustomerAddressInput } from "@/lib/validation/customerApp"
import type { AddressRow } from "@/services/customerApp"

/**
 * Shared add/edit address form — used by the Profile page's address list and
 * by AddressPickerModal (Task 3, 2026-07-30) so both stay on one
 * validation/markup path instead of two copies drifting apart.
 *
 * Root-cause fix (bug: "technician's map location doesn't match the
 * customer's actual location, and distance/ETA are wrong"): this form used
 * to be text-only — it never captured `lat`/`lng` at all, so every address a
 * customer added or edited through their own Profile/booking flow had
 * permanently null coordinates, and the technician's Map page had nothing
 * real to plot or compute a distance from. Now mounts the same
 * `AddressMapPicker` the admin-side customer form already uses (search,
 * drag-to-adjust, "use my location"), required before the address can be
 * saved.
 */
export function AddressForm({
  initial,
  onCancel,
  onSubmit,
  isPending,
  error,
}: {
  initial?: AddressRow
  onCancel: () => void
  onSubmit: (values: CustomerAddressInput) => void
  isPending: boolean
  error?: string
}) {
  const { t } = useTranslation()
  const uid = useId()
  const {
    register,
    handleSubmit,
    watch,
    setValue,
    getValues,
    formState: { errors },
  } = useForm<CustomerAddressInput>({
    resolver: zodResolver(customerAddressSchema),
    mode: "onChange",
    defaultValues: {
      doorNo: initial?.door_no ?? "",
      flatNo: initial?.flat_no ?? "",
      streetCross: initial?.street_cross ?? "",
      area: initial?.area ?? "",
      pincode: initial?.pincode ?? "",
      landmark: initial?.landmark ?? "",
      district: initial?.district ?? "",
      state: initial?.state ?? "",
      addressType: initial?.address_type ?? "residential",
      ownership: initial?.ownership ?? "own",
      lat: initial?.lat ?? undefined,
      lng: initial?.lng ?? undefined,
    },
  })
  const lat = watch("lat")
  const lng = watch("lng")
  const [doorNo, flatNo, streetCross, area, pincode, landmark, district, state] = watch([
    "doorNo",
    "flatNo",
    "streetCross",
    "area",
    "pincode",
    "landmark",
    "district",
    "state",
  ])
  const locationText = [doorNo, flatNo, streetCross, area, pincode, landmark, district, state].join("|")
  // Bug fix: editing an existing address's text (e.g. correcting the door
  // number/area to a real address after it was saved with a placeholder)
  // used to leave the OLD pin's lat/lng untouched — the map picker showed it
  // as already-confirmed, so nothing prompted a re-check, and the
  // technician's "Open in Maps" silently navigated to wherever the stale pin
  // was instead of the corrected address. Snapshot the text the currently
  // confirmed pin belongs to, and drop the pin the moment the text diverges
  // from it, so `mapRequired` below fires and the user must re-confirm.
  const confirmedLocationTextRef = useRef(locationText)
  useEffect(() => {
    if ((lat == null && lng == null) || locationText === confirmedLocationTextRef.current) return
    setValue("lat", undefined, { shouldValidate: true })
    setValue("lng", undefined, { shouldValidate: true })
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [locationText])

  // Auto-places a SUGGESTED map pin from the address fields already typed
  // above, once there's enough to geocode meaningfully — same fix already
  // applied on the admin-side CustomerFormPage (v2.2 feedback there: typing
  // the same address twice, once in these fields and again into the map's
  // own search box, was redundant and error-prone). Fires only while no pin
  // exists yet: once set, by this or by the customer's own search/drag, later
  // field edits must not silently yank an already-placed pin out from under
  // them (that's what the confirmedLocationTextRef effect above already
  // guards via clearing lat/lng, which re-opens this effect to suggest again).
  const geocodeAddress = useGeocodeAddress()
  const autoLocateQuery = [doorNo, flatNo, streetCross, area, landmark, pincode, district, state].filter(Boolean).join(", ")
  const debouncedAutoLocateQuery = useDebouncedValue(autoLocateQuery, 800)
  const [suggestedPin, setSuggestedPin] = useState<{ lat: number; lng: number; formatted: string; precise: boolean } | null>(null)
  useEffect(() => {
    if (lat != null && lng != null) return
    if (!area.trim() || pincode.trim().length !== 6) return
    geocodeAddress.mutate(debouncedAutoLocateQuery, {
      onSuccess: (results) => {
        const top = results[0]
        if (!top) return
        // Re-check fresh values, not the stale closure above — the request
        // was in flight for a moment, and the customer may have already
        // searched/dragged/confirmed a pin themselves in that window.
        if (getValues("lat") != null && getValues("lng") != null) return
        setSuggestedPin({ lat: top.lat, lng: top.lon, formatted: top.formatted, precise: isPreciseGeocodeResult(top.locationType) })
      },
    })
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [debouncedAutoLocateQuery, pincode, lat, lng])

  useEffect(() => {
    setSuggestedPin(null)
  }, [locationText])

  return (
    <form onSubmit={handleSubmit(onSubmit)} className="space-y-2.5 border-t border-border pt-3">
      <div className="grid grid-cols-2 gap-2.5">
        <div className="space-y-1">
          <Label htmlFor={`${uid}-doorNo`} className="sr-only">{t("customerApp.profile.address.doorNo")}</Label>
          <Input id={`${uid}-doorNo`} placeholder={t("customerApp.profile.address.doorNo")} aria-invalid={!!errors.doorNo} {...register("doorNo")} />
          {errors.doorNo ? <p className="text-xs text-danger">{t(errors.doorNo.message!)}</p> : null}
        </div>
        <div className="space-y-1">
          <Label htmlFor={`${uid}-flatNo`} className="sr-only">{t("customerApp.profile.address.flatNo")}</Label>
          <Input id={`${uid}-flatNo`} placeholder={t("customerApp.profile.address.flatNo")} {...register("flatNo")} />
        </div>
      </div>
      <div className="space-y-1">
        <Label htmlFor={`${uid}-streetCross`} className="sr-only">{t("customerApp.profile.address.streetCross")}</Label>
        <Input id={`${uid}-streetCross`} placeholder={t("customerApp.profile.address.streetCross")} {...register("streetCross")} />
      </div>
      <div className="space-y-1">
        <Label htmlFor={`${uid}-area`} className="sr-only">{t("customerApp.profile.address.area")}</Label>
        <Input id={`${uid}-area`} placeholder={t("customerApp.profile.address.area")} aria-invalid={!!errors.area} {...register("area")} />
        {errors.area ? <p className="text-xs text-danger">{t(errors.area.message!)}</p> : null}
      </div>
      <div className="grid grid-cols-2 gap-2.5">
        <div className="space-y-1">
          <Label htmlFor={`${uid}-pincode`} className="sr-only">{t("customerApp.profile.address.pincode")}</Label>
          <Input id={`${uid}-pincode`} placeholder={t("customerApp.profile.address.pincode")} aria-invalid={!!errors.pincode} {...register("pincode")} />
          {errors.pincode ? <p className="text-xs text-danger">{t(errors.pincode.message!)}</p> : null}
        </div>
        <div className="space-y-1">
          <Label htmlFor={`${uid}-landmark`} className="sr-only">{t("customerApp.profile.address.landmark")}</Label>
          <Input id={`${uid}-landmark`} placeholder={t("customerApp.profile.address.landmark")} {...register("landmark")} />
        </div>
      </div>
      <div className="grid grid-cols-2 gap-2.5">
        <Input placeholder={t("customerApp.profile.address.district")} {...register("district")} />
        <Input placeholder={t("customerApp.profile.address.state")} {...register("state")} />
      </div>

      <div className="space-y-1">
        <div className="flex items-center gap-1.5">
          <Label className="text-xs text-text-muted">{t("customerApp.profile.address.mapLabel")}</Label>
          {geocodeAddress.isPending && lat == null ? (
            <span className="flex items-center gap-1 text-xs text-text-muted">
              <Loader2 className="size-3 animate-spin" />
              {t("customers.form.map.autoLocating")}
            </span>
          ) : null}
        </div>
        <p className="text-xs text-text-muted">{t("customerApp.profile.address.mapHint")}</p>
        <AddressMapPicker
          lat={lat}
          lng={lng}
          suggestedLat={suggestedPin?.lat}
          suggestedLng={suggestedPin?.lng}
          suggestedFormatted={suggestedPin?.formatted}
          suggestedPrecise={suggestedPin?.precise}
          onConfirm={({ lat: newLat, lng: newLng }) => {
            setValue("lat", newLat, { shouldValidate: true })
            setValue("lng", newLng, { shouldValidate: true })
            setSuggestedPin(null)
            confirmedLocationTextRef.current = locationText
          }}
          onAddressSelect={(r) => {
            if (!getValues("area") && (r.suburb || r.city)) setValue("area", r.suburb ?? r.city ?? "", { shouldValidate: true })
            if (!getValues("pincode") && r.postcode) setValue("pincode", r.postcode, { shouldValidate: true })
            if (!getValues("district") && r.district) setValue("district", r.district, { shouldValidate: true })
            if (!getValues("state") && r.state) setValue("state", r.state, { shouldValidate: true })
          }}
        />
        {lat == null || lng == null ? <p className="text-xs text-warning">{t("customerApp.profile.address.mapRequired")}</p> : null}
      </div>

      <div className="grid grid-cols-2 gap-2.5">
        <div className="space-y-1">
          <Label htmlFor={`${uid}-addressType`} className="text-xs text-text-muted">{t("customerApp.profile.address.type")}</Label>
          <select id={`${uid}-addressType`} className="h-10 w-full rounded-xl border border-input bg-surface px-3 text-sm text-text outline-none transition-colors focus-visible:border-ring focus-visible:ring-3 focus-visible:ring-ring/30" {...register("addressType")}>
            <option value="residential">{t("customerApp.profile.address.residential")}</option>
            <option value="commercial">{t("customerApp.profile.address.commercial")}</option>
          </select>
        </div>
        <div className="space-y-1">
          <Label htmlFor={`${uid}-ownership`} className="text-xs text-text-muted">{t("customerApp.profile.address.ownership")}</Label>
          <select id={`${uid}-ownership`} className="h-10 w-full rounded-xl border border-input bg-surface px-3 text-sm text-text outline-none transition-colors focus-visible:border-ring focus-visible:ring-3 focus-visible:ring-ring/30" {...register("ownership")}>
            <option value="own">{t("customerApp.profile.address.own")}</option>
            <option value="rental">{t("customerApp.profile.address.rental")}</option>
          </select>
        </div>
      </div>
      {error ? <p className="text-xs text-danger">{error}</p> : null}
      <div className="flex justify-end gap-2">
        <Button type="button" size="sm" variant="ghost" onClick={onCancel}>
          {t("common.cancel")}
        </Button>
        <Button type="submit" size="sm" disabled={isPending || lat == null || lng == null}>
          {isPending ? <Loader2 className="size-3.5 animate-spin" /> : t("common.save")}
        </Button>
      </div>
    </form>
  )
}
