import { useTranslation } from "react-i18next"
import { zodResolver } from "@hookform/resolvers/zod"
import { useForm } from "react-hook-form"
import { Loader2 } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { AddressMapPicker } from "@/components/shared/AddressMapPicker"
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

  return (
    <form onSubmit={handleSubmit(onSubmit)} className="space-y-2.5 border-t border-border pt-3">
      <div className="grid grid-cols-2 gap-2.5">
        <div className="space-y-1">
          <Input placeholder={t("customerApp.profile.address.doorNo")} aria-invalid={!!errors.doorNo} {...register("doorNo")} />
          {errors.doorNo ? <p className="text-xs text-danger">{t(errors.doorNo.message!)}</p> : null}
        </div>
        <div className="space-y-1">
          <Input placeholder={t("customerApp.profile.address.flatNo")} {...register("flatNo")} />
        </div>
      </div>
      <Input placeholder={t("customerApp.profile.address.streetCross")} {...register("streetCross")} />
      <div className="space-y-1">
        <Input placeholder={t("customerApp.profile.address.area")} aria-invalid={!!errors.area} {...register("area")} />
        {errors.area ? <p className="text-xs text-danger">{t(errors.area.message!)}</p> : null}
      </div>
      <div className="grid grid-cols-2 gap-2.5">
        <div className="space-y-1">
          <Input placeholder={t("customerApp.profile.address.pincode")} aria-invalid={!!errors.pincode} {...register("pincode")} />
          {errors.pincode ? <p className="text-xs text-danger">{t(errors.pincode.message!)}</p> : null}
        </div>
        <Input placeholder={t("customerApp.profile.address.landmark")} {...register("landmark")} />
      </div>
      <div className="grid grid-cols-2 gap-2.5">
        <Input placeholder={t("customerApp.profile.address.district")} {...register("district")} />
        <Input placeholder={t("customerApp.profile.address.state")} {...register("state")} />
      </div>

      <div className="space-y-1">
        <Label className="text-xs text-text-muted">{t("customerApp.profile.address.mapLabel")}</Label>
        <p className="text-xs text-text-muted">{t("customerApp.profile.address.mapHint")}</p>
        <AddressMapPicker
          lat={lat}
          lng={lng}
          onConfirm={({ lat: newLat, lng: newLng }) => {
            setValue("lat", newLat, { shouldValidate: true })
            setValue("lng", newLng, { shouldValidate: true })
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
          <Label className="text-xs text-text-muted">{t("customerApp.profile.address.type")}</Label>
          <select className="h-10 w-full rounded-xl border border-border bg-surface px-3 text-sm text-text outline-none" {...register("addressType")}>
            <option value="residential">{t("customerApp.profile.address.residential")}</option>
            <option value="commercial">{t("customerApp.profile.address.commercial")}</option>
          </select>
        </div>
        <div className="space-y-1">
          <Label className="text-xs text-text-muted">{t("customerApp.profile.address.ownership")}</Label>
          <select className="h-10 w-full rounded-xl border border-border bg-surface px-3 text-sm text-text outline-none" {...register("ownership")}>
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
