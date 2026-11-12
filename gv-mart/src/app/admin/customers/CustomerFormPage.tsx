import { useEffect, useRef, useState } from "react"
import { useTranslation } from "react-i18next"
import { useNavigate, useParams } from "react-router-dom"
import { useFieldArray, useForm, type Control, type FieldErrors, type UseFormRegister, type UseFormWatch } from "react-hook-form"
import { zodResolver } from "@hookform/resolvers/zod"
import { Loader2, Pencil, Plus, Star, Trash2 } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { Card } from "@/components/ui/card"
import { Stepper } from "@/components/shared/Stepper"
import { SegButton } from "@/components/shared/SegButton"
import { Autocomplete } from "@/components/shared/Autocomplete"
import { AddressMapPicker } from "@/components/shared/AddressMapPicker"
import { ReferrerPicker } from "@/components/shared/ReferrerPicker"
import { FullPageError, FullPageLoader } from "@/components/shared/FullPageLoader"
import { useToast } from "@/components/ui/toast-context"
import { PreferredLanguageSelect } from "@/components/shared/PreferredLanguageSelect"
import { StatusDot } from "@/components/shared/StatusDot"
import { FamilyMembersPanel } from "./FamilyMembersPanel"
import { WaterHouseholdPanel } from "./WaterHouseholdPanel"
import {
  addressStepSchema,
  peopleStepSchema,
  canSkipAddressPin,
  FAMILY_RELATIONS,
  canEditWaterHousehold,
  type AddressStepInput,
  type PeopleStepInput,
} from "@/lib/validation/customer"
import { useProfile } from "@/hooks/useProfile"
import { useDebouncedValue } from "@/hooks/useDebouncedValue"
import { useGeocodeAddress } from "@/hooks/useMaps"
import { isPreciseGeocodeResult } from "@/services/maps"
import {
  getPrimaryAddressId,
  setAddressStructuredFields,
  setAddressWaterHousehold,
  setAddressZone,
  setCustomerPreferredLanguage,
  updateCustomerEmail,
} from "@/services/customers"
import { composeFullAddress, splitAddressForForm } from "@/lib/address"
import {
  useAreaAutocomplete,
  useCreateCustomer,
  useCustomer,
  useDuplicateContactWarning,
  useLandmarkAutocomplete,
  useMobileDuplicateCheck,
  usePincodeLookup,
  usePincodeSuggestions,
  useStreetCrossAutocomplete,
  useSubAreaAutocomplete,
  useUpdateCustomerEmail,
  useUpsertPrimaryAddress,
} from "@/hooks/useCustomers"
import { canSubmitWithWarning, duplicateWarningKey } from "@/lib/duplicateContactWarning"
import { DuplicateContactWarning } from "@/components/shared/DuplicateContactWarning"
import { guardReentry } from "@/lib/async-guard"

/** Mirrors the RPC's has_address: any address text or a map pin (type/ownership alone don't count). */
function hasAddressText(a: AddressStepInput) {
  return (
    [a.doorNo, a.plotNo, a.buildingName, a.streetCross, a.subArea, a.landmark, a.fullAddress, a.area, a.pincode, a.district, a.state, a.zone].some(
      (v) => v?.trim()
    ) ||
    a.lat != null ||
    a.lng != null
  )
}

function MemberFieldRow({
  index,
  control,
  register,
  errors,
  watch,
  orgId,
  isPrimary,
  canRemove,
  onSetPrimary,
  onRemove,
}: {
  index: number
  control: Control<PeopleStepInput>
  register: UseFormRegister<PeopleStepInput>
  errors: FieldErrors<PeopleStepInput>
  watch: UseFormWatch<PeopleStepInput>
  orgId: string | undefined
  isPrimary: boolean
  canRemove: boolean
  onSetPrimary: () => void
  onRemove: () => void
}) {
  const { t } = useTranslation()
  const mobile = watch(`members.${index}.mobile`)
  const dup = useMobileDuplicateCheck(orgId, mobile)
  const [confirmingRemove, setConfirmingRemove] = useState(false)
  void control

  return (
    <div className="rounded-xl border border-border p-3.5">
      <div className="flex items-start gap-2">
        <div className="flex-1 space-y-1">
          <Input placeholder={t("customers.form.memberName")} aria-invalid={!!errors.members?.[index]?.name} {...register(`members.${index}.name`)} />
          {errors.members?.[index]?.name ? <p className="text-xs text-danger">{t(errors.members[index]!.name!.message!)}</p> : null}
        </div>
        <div className="flex-1 space-y-1">
          <Input
            placeholder={t("customers.form.memberMobile")}
            aria-invalid={!!errors.members?.[index]?.mobile}
            {...register(`members.${index}.mobile`)}
          />
          {errors.members?.[index]?.mobile ? <p className="text-xs text-danger">{t(errors.members[index]!.mobile!.message!)}</p> : null}
          {dup.data ? (
            <p className="text-xs text-warning">{t("customers.form.duplicateWarning", { name: dup.data.name })}</p>
          ) : null}
        </div>
      </div>
      <div className="mt-2 flex gap-2">
        <div className="flex-1 space-y-1">
          <Input placeholder={t("customers.form.memberProfession")} {...register(`members.${index}.profession`)} />
        </div>
        <div className="flex-1 space-y-1">
          <Input
            type="email"
            placeholder={t("customers.form.memberEmail")}
            aria-invalid={!!errors.members?.[index]?.email}
            {...register(`members.${index}.email`)}
          />
          {errors.members?.[index]?.email ? <p className="text-xs text-danger">{t(errors.members[index]!.email!.message!)}</p> : null}
        </div>
      </div>
      <div className="mt-2 flex flex-wrap items-center justify-between gap-2">
        {/* Primary member IS the customer — relation-to-household doesn't apply to them. */}
        {!isPrimary ? (
          <select
            aria-label={t("customers.form.memberRelation")}
            defaultValue=""
            className="h-9 rounded-xl border border-border bg-surface px-3 text-sm text-text outline-none"
            {...register(`members.${index}.relation`)}
          >
            <option value="">{t("customers.form.memberRelationPlaceholder")}</option>
            {FAMILY_RELATIONS.map((r) => (
              <option key={r} value={r}>
                {t(`customers.form.relation.${r}`)}
              </option>
            ))}
          </select>
        ) : (
          <span className="flex items-center gap-1 rounded-full bg-accent-soft px-2 py-0.5 text-[10px] font-bold text-accent">
            <Star className="size-2.5 fill-current" />
            {t("customers.detail.primary")}
          </span>
        )}
        <div className="flex items-center gap-x-2.5 text-xs">
          {!isPrimary ? (
            <button type="button" className="font-semibold text-text-muted hover:text-text" onClick={onSetPrimary}>
              {t("customers.detail.setPrimary")}
            </button>
          ) : null}
          {canRemove && !confirmingRemove ? (
            <button
              type="button"
              className="flex items-center gap-1 font-semibold text-danger hover:underline"
              title={t("customers.detail.remove")}
              onClick={() => setConfirmingRemove(true)}
            >
              <Trash2 className="size-3" />
            </button>
          ) : null}
          {canRemove && confirmingRemove ? (
            <span className="flex items-center gap-1.5">
              <button
                type="button"
                className="font-semibold text-danger hover:underline"
                onClick={() => {
                  onRemove()
                  setConfirmingRemove(false)
                }}
              >
                {t("customers.detail.confirm")}
              </button>
              <button type="button" className="text-text-muted hover:underline" onClick={() => setConfirmingRemove(false)}>
                {t("common.cancel")}
              </button>
            </span>
          ) : null}
        </div>
      </div>
    </div>
  )
}

export function CustomerFormPage() {
  const { t } = useTranslation()
  const { toast } = useToast()
  const navigate = useNavigate()
  const { id } = useParams<{ id?: string }>()
  const mode: "create" | "edit" = id ? "edit" : "create"
  const { data: profile } = useProfile()
  const orgId = profile?.org_id
  const pinOptional = canSkipAddressPin(profile?.role)

  const existing = useCustomer(mode === "edit" ? id : undefined)
  const [step, setStep] = useState(0)
  // Edit mode: the account holder's own email, independent of the people-step wizard form
  // (which only exists for create mode) -- saved immediately, same "edit one field, save it
  // right away" shape as FamilyMembersPanel's own per-member edits below it.
  const [editEmail, setEditEmail] = useState("")
  const updateEmail = useUpdateCustomerEmail(id ?? "")
  // Only ever grows — tracks the furthest step reached so navigating back
  // (which decreases `step`) doesn't make already-completed steps lose their
  // checkmark in the Stepper below. See Stepper's `maxCompletedIndex` doc.
  const [maxStepReached, setMaxStepReached] = useState(0)

  const peopleForm = useForm<PeopleStepInput>({
    resolver: zodResolver(peopleStepSchema),
    mode: "onChange",
    defaultValues: { members: [{ name: "", mobile: "" }], primaryIndex: 0, profession: "", referredByUserId: "" },
  })
  const { fields, append, remove } = useFieldArray({ control: peopleForm.control, name: "members" })
  const primaryIndex = peopleForm.watch("primaryIndex")

  // Urgent item (2026-11-02): staff-side duplicate-contact warning (not a
  // hard block -- see DuplicateContactWarning's own header). Only looked up
  // in create mode, against the primary member's own mobile + the top-level
  // email field (the two identifiers find_duplicate_contacts matches on).
  const primaryMobile = peopleForm.watch(`members.${primaryIndex}.mobile`) ?? ""
  const topEmail = peopleForm.watch("email") ?? ""
  const dupWarning = useDuplicateContactWarning(mode === "create" ? orgId : undefined, primaryMobile, topEmail)
  const dupWarningKey = duplicateWarningKey(primaryMobile, topEmail)
  // Tracks WHICH (mobile, email) pair was confirmed, not just a bare
  // boolean, so editing the number after confirming resets the gate instead
  // of silently carrying the old confirmation over to a new number.
  const [confirmedDupWarningKey, setConfirmedDupWarningKey] = useState<string | null>(null)
  const dupWarningConfirmed = confirmedDupWarningKey === dupWarningKey

  const addressForm = useForm<AddressStepInput>({
    resolver: zodResolver(addressStepSchema),
    mode: "onChange",
    defaultValues: {
      doorNo: "",
      plotNo: "",
      buildingName: "",
      streetCross: "",
      subArea: "",
      landmark: "",
      fullAddress: "",
      area: "",
      pincode: "",
      district: "",
      state: "",
      zone: "",
      addressType: "residential",
      ownership: "own",
      lat: undefined,
      lng: undefined,
      waterSource: "",
      waterTds: undefined,
      waterPh: undefined,
      healthCondition: "",
    },
  })
  const [waterEditing, setWaterEditing] = useState(false)
  // Shown only for a customer saved before the structured fields existed
  // (every structured column still empty) — editing their address falls
  // back to the old free-text box instead of looking blank. See
  // splitAddressForForm in src/lib/address.ts.
  const [hasLegacyAddressOnly, setHasLegacyAddressOnly] = useState(false)
  const doorNo = addressForm.watch("doorNo") ?? ""
  const plotNo = addressForm.watch("plotNo") ?? ""
  const buildingName = addressForm.watch("buildingName") ?? ""
  const streetCross = addressForm.watch("streetCross") ?? ""
  const subArea = addressForm.watch("subArea") ?? ""
  const landmark = addressForm.watch("landmark") ?? ""
  const legacyFullAddress = addressForm.watch("fullAddress") ?? ""
  const area = addressForm.watch("area") ?? ""
  const pincode = addressForm.watch("pincode")
  const district = addressForm.watch("district")
  const state = addressForm.watch("state")
  const lat = addressForm.watch("lat")
  const lng = addressForm.watch("lng")
  // The canonical composed text geocoding/compare/save all use — structured
  // fields take over the moment any of them has text; otherwise this falls
  // back to the old free-text full_address so a pre-redesign customer's
  // address isn't silently dropped. See src/lib/address.ts.
  const fullAddress = composeFullAddress({ doorNo, plotNo, buildingName, streetCross, subArea, area, landmark }) || legacyFullAddress
  const areaAutocomplete = useAreaAutocomplete(orgId, area)
  const landmarkAutocomplete = useLandmarkAutocomplete(orgId, landmark)
  const streetCrossAutocomplete = useStreetCrossAutocomplete(orgId, streetCross)
  const subAreaAutocomplete = useSubAreaAutocomplete(orgId, subArea)
  const pincodeSuggestions = usePincodeSuggestions(orgId, pincode)
  const pincodeLookup = usePincodeLookup(orgId, pincode)
  const autoLocate = useGeocodeAddress()

  useEffect(() => {
    if (pincodeLookup.data && !addressForm.getValues("district")) {
      addressForm.setValue("district", pincodeLookup.data.district ?? "")
      addressForm.setValue("state", pincodeLookup.data.state ?? "")
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [pincodeLookup.data])

  // Auto-places a SUGGESTED map pin from the address fields already typed
  // above (v2.2 feedback: typing the same address twice — once here, once
  // again into the map's own search box — was redundant and error-prone),
  // once there's enough to geocode meaningfully. Fires only while no pin
  // exists yet: once set, by this or by staff's own search/drag, later
  // edits to these fields must not silently yank an already-placed pin out
  // from under them.
  //
  // Root-cause fix (bug: "technician's map location doesn't match the
  // customer's actual location"): this used to (a) omit doorNo/
  // pincode from the geocoded string even though pincode gates the effect,
  // so Google had nothing more precise than street+area+landmark to work
  // with — routinely resolving to the street/locality centroid rather than
  // the actual premise — and (b) wrote straight into the form's lat/lng,
  // which AddressMapPicker renders as an already-CONFIRMED green pin with
  // no prompt to verify, so an imprecise guess shipped silently. Fixed by
  // sending the full address (including door/flat number and pincode) and
  // by passing the result as `suggestedLat`/`suggestedLng` instead — that
  // renders as an amber DRAFT pin (draggable, "needs confirmation") that
  // staff must explicitly confirm or correct, exactly like every other
  // ambiguous "search anyway" result already behaves.
  // `fullAddress` already folds `area` in (see composeFullAddress above), so
  // it isn't repeated here.
  const autoLocateQuery = [fullAddress, pincode, district, state].filter(Boolean).join(", ")
  const debouncedAutoLocateQuery = useDebouncedValue(autoLocateQuery, 800)
  const [suggestedPin, setSuggestedPin] = useState<{ lat: number; lng: number; formatted: string; precise: boolean } | null>(null)
  useEffect(() => {
    if (lat != null && lng != null) return
    if (!area.trim() || pincode.trim().length !== 6) return
    autoLocate.mutate(debouncedAutoLocateQuery, {
      onSuccess: (results) => {
        const top = results[0]
        if (!top) return
        // Re-check fresh values, not the stale closure above — the request
        // was in flight for a moment, and staff may have already
        // searched/dragged/confirmed a pin themselves in that window.
        if (addressForm.getValues("lat") != null && addressForm.getValues("lng") != null) return
        setSuggestedPin({ lat: top.lat, lng: top.lon, formatted: top.formatted, precise: isPreciseGeocodeResult(top.locationType) })
      },
    })
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [debouncedAutoLocateQuery, pincode, lat, lng])

  // Bug fix: this effect's guard above ("once set... later edits must not
  // silently yank an already-placed pin") was written to protect a pin staff
  // just placed *this session* — but it also protected a STALE pin loaded
  // from an existing customer's DB row when staff corrects that address's
  // text afterwards (e.g. a placeholder door/area later fixed to the real
  // one). The pin then keeps pointing at the old address with nothing
  // prompting a re-check, so the technician's "Open in Maps" ends up at the
  // wrong place. Snapshot the text the currently-confirmed pin belongs to
  // (set on load and whenever a pin is confirmed below) and clear the pin
  // the moment the address text diverges from it, so the auto-suggest effect
  // above treats it like a fresh, unconfirmed address again.
  const confirmedLocationTextRef = useRef(autoLocateQuery)
  useEffect(() => {
    if ((lat == null && lng == null) || autoLocateQuery === confirmedLocationTextRef.current) return
    addressForm.setValue("lat", undefined, { shouldValidate: true })
    addressForm.setValue("lng", undefined, { shouldValidate: true })
    setSuggestedPin(null)
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [autoLocateQuery])

  useEffect(() => {
    if (mode === "edit" && existing.data) {
      peopleForm.reset({ members: [], primaryIndex: 0, profession: existing.data.profession ?? "" })
      setEditEmail(existing.data.email ?? "")
      const primary = existing.data.addresses.find((a) => a.is_primary) ?? existing.data.addresses[0]
      if (primary) {
        // Structured columns win when any are populated; a customer saved
        // before this redesign (all structured columns empty) falls back to
        // showing the old free-text full_address instead, so editing it
        // doesn't look blank. See src/lib/address.ts.
        const split = splitAddressForForm(primary)
        setHasLegacyAddressOnly(!split.hasStructuredFields && !!split.legacyFullAddress)
        addressForm.reset({
          doorNo: split.doorNo,
          plotNo: split.plotNo,
          buildingName: split.buildingName,
          streetCross: split.streetCross,
          subArea: split.subArea,
          landmark: split.landmark,
          fullAddress: split.legacyFullAddress,
          area: split.area,
          pincode: primary.pincode ?? "",
          district: primary.district ?? "",
          state: primary.state ?? "",
          zone: primary.zone ?? "",
          addressType: primary.address_type,
          ownership: primary.ownership,
          lat: primary.lat ?? undefined,
          lng: primary.lng ?? undefined,
          waterSource: primary.water_source ?? "",
          waterTds: primary.water_tds ?? undefined,
          waterPh: primary.water_ph ?? undefined,
          healthCondition: primary.health_condition ?? "",
        })
        const composed = composeFullAddress(split) || split.legacyFullAddress
        confirmedLocationTextRef.current = [composed, primary.pincode, primary.district, primary.state].filter(Boolean).join(", ")
      }
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [mode, existing.data])

  const createCustomer = useCreateCustomer()
  const upsertAddress = useUpsertPrimaryAddress(orgId, id ?? "")
  // Urgent item (2026-11-02): root-cause investigation into "error popup yet
  // one entry still gets created" found this Save button had no re-entrancy
  // guard, unlike AccountsPage's "+ Create" buttons -- isPending/disabled
  // alone doesn't close the window between two fast clicks both reaching
  // this handler before the first re-render (see async-guard.ts's own
  // header). create_customer_with_details has no dedupe check by design, so
  // a double-submit here would create two full customer rows, not just a
  // stray error. No live evidence this has actually happened yet (the real
  // duplicates found were ordinary single-submits against an already-warned
  // number, see the migration header), but it's a real latent gap closed
  // here regardless.
  const savingRef = useRef(false)

  if (mode === "edit" && existing.isLoading) return <FullPageLoader label={t("common.loading")} />
  if (mode === "edit" && (existing.isError || !existing.data)) {
    return <FullPageError message={t("customers.error.loadFailed")} onRetry={() => existing.refetch()} retryLabel={t("common.retry")} />
  }

  const steps = [
    { key: "people", label: t("customers.form.stepPeople") },
    { key: "address", label: t("customers.form.stepAddress") },
    { key: "water", label: t("customers.form.stepWater") },
  ]

  async function handleNext() {
    if (mode === "create") {
      const valid = await peopleForm.trigger()
      if (!valid) return
    }
    setStep(1)
    setMaxStepReached((m) => Math.max(m, 1))
  }

  async function handleAddressNext() {
    const valid = await addressForm.trigger(["pincode"])
    if (!valid) return
    setStep(2)
    setMaxStepReached((m) => Math.max(m, 2))
  }

  async function handleSaveAndFinish() {
    await guardReentry(savingRef, async () => {
      await handleSaveAndFinishInner()
    })
  }

  async function handleSaveAndFinishInner() {
    const valid = await addressForm.trigger()
    if (!valid) return
    const addressValues = addressForm.getValues()
    // Structured fields are the source of truth the moment any is filled;
    // only a customer that still has nothing but the legacy fallback box
    // keeps that text as full_address. See composeFullAddress in src/lib/address.ts.
    const composedFullAddress = composeFullAddress(addressValues) || addressValues.fullAddress?.trim() || ""

    if (mode === "create") {
      const peopleValues = peopleForm.getValues()
      const referredByUserId = peopleValues.referredByUserId || undefined
      const newId = await createCustomer.mutateAsync({
        orgId: orgId!,
        // The primary member's own profession becomes the customer's (the RPC also falls back to it).
        profession: peopleValues.members[peopleValues.primaryIndex]?.profession?.trim() || undefined,
        referredByUserId,
        members: peopleValues.members.map((m, i) => ({
          name: m.name,
          mobile: m.mobile,
          isPrimary: i === peopleValues.primaryIndex,
          relation: i === peopleValues.primaryIndex ? undefined : m.relation || undefined,
          profession: m.profession?.trim() || undefined,
          email: m.email?.trim() || undefined,
        })),
        address: {
          fullAddress: composedFullAddress,
          area: addressValues.area,
          pincode: addressValues.pincode,
          district: addressValues.district,
          state: addressValues.state,
          addressType: addressValues.addressType,
          ownership: addressValues.ownership,
          lat: addressValues.lat,
          lng: addressValues.lng,
        },
      })
      // Self-referral / anti-abuse guard (stage2_corrections_addendum.md item 9) — a
      // referral attempt can be silently nulled server-side rather than erroring, so
      // the save must never fail; this is just a non-blocking heads-up. The RPC
      // (create_customer_with_details) currently returns only the new customer id
      // (a bare string), so there is nothing yet to inspect here — once the DB
      // stream's RPC starts returning a richer shape with an explicit
      // `referral_attributed: boolean` flag, surface the same toast as the lead
      // form does when that flag comes back false.
      if (referredByUserId && typeof newId === "object" && (newId as { referral_attributed?: boolean }).referral_attributed === false) {
        toast.warning(t("common.referralNotRecorded"))
      }
      // The create RPC has no language argument: a small follow-up write, like the zone below. The customer already exists, so a
      // failure only warns and can be re-entered from the customer page.
      if (peopleValues.preferredLanguage === "en" || peopleValues.preferredLanguage === "ta") {
        try {
          await setCustomerPreferredLanguage(newId, peopleValues.preferredLanguage)
        } catch {
          toast.error(t("common.actionFailed"))
        }
      }
      // create_customer_with_details (RPC) doesn't accept an email either -- same small
      // follow-up write shape as the language field above (updateCustomerEmail normalizes
      // trim+lowercase).
      if (peopleValues.email?.trim()) {
        try {
          await updateCustomerEmail(newId, peopleValues.email)
        } catch {
          toast.error(t("common.actionFailed"))
        }
      }
      // create_customer_with_details (RPC) doesn't accept a zone — set it as
      // a small direct follow-up write on the primary address it just created.
      // The customer itself is already created at this point, so a failure
      // here shouldn't block navigation — just warn so it can be re-entered
      // via edit.
      if (addressValues.zone?.trim() && hasAddressText(addressValues)) {
        try {
          const primaryAddressId = await getPrimaryAddressId(newId)
          await setAddressZone(primaryAddressId, addressValues.zone.trim())
        } catch {
          toast.error(t("common.actionFailed"))
        }
      }
      // Clean-address-form redesign — create_customer_with_details only
      // accepts full_address/area/pincode/district/state — the structured
      // columns behind Door no/Plot no/Building Name/Street-Cross/Sub Area/
      // Landmark get the same direct follow-up write as zone above.
      const hasStructuredFields =
        addressValues.doorNo?.trim() ||
        addressValues.plotNo?.trim() ||
        addressValues.buildingName?.trim() ||
        addressValues.streetCross?.trim() ||
        addressValues.subArea?.trim() ||
        addressValues.landmark?.trim()
      if (hasStructuredFields && hasAddressText(addressValues)) {
        try {
          const primaryAddressId = await getPrimaryAddressId(newId)
          await setAddressStructuredFields(primaryAddressId, {
            doorNo: addressValues.doorNo?.trim() || undefined,
            plotNo: addressValues.plotNo?.trim() || undefined,
            buildingName: addressValues.buildingName?.trim() || undefined,
            streetCross: addressValues.streetCross?.trim() || undefined,
            subArea: addressValues.subArea?.trim() || undefined,
            landmark: addressValues.landmark?.trim() || undefined,
          })
        } catch {
          toast.error(t("common.actionFailed"))
        }
      }
      // Water & household step — same follow-up-write reasoning as zone
      // above (the create RPC has no slot for these), and the same guard:
      // no addresses row exists at all unless some address text was given.
      const hasWaterValues =
        addressValues.waterSource?.trim() || addressValues.waterTds != null || addressValues.waterPh != null || addressValues.healthCondition?.trim()
      if (hasWaterValues && hasAddressText(addressValues)) {
        try {
          const primaryAddressId = await getPrimaryAddressId(newId)
          await setAddressWaterHousehold(primaryAddressId, {
            waterSource: addressValues.waterSource?.trim() || undefined,
            waterTds: addressValues.waterTds,
            waterPh: addressValues.waterPh,
            healthCondition: addressValues.healthCondition?.trim() || undefined,
          })
        } catch {
          toast.error(t("common.actionFailed"))
        }
      }
      navigate(`/admin/customers/${newId}`)
      return
    }

    // edit mode (profession is edited per member now; the primary member's change also updates the customer)
    const existingAddressId = existing.data!.addresses.find((a) => a.is_primary)?.id ?? existing.data!.addresses[0]?.id ?? null
    // Blank address on a customer with none stays "needs setup" — no empty row.
    if (existingAddressId || hasAddressText(addressValues)) {
      await upsertAddress.mutateAsync({ existingAddressId, patch: { ...addressValues, fullAddress: composedFullAddress } })
    }
    navigate(`/admin/customers/${id}`)
  }

  const isSaving = createCustomer.isPending || upsertAddress.isPending
  const saveError = (createCustomer.error ?? upsertAddress.error) as Error | null

  return (
    <div className="mx-auto max-w-2xl space-y-4 pt-2">
      <h1 className="text-2xl font-bold text-text">
        {mode === "create" ? t("customers.form.createTitle") : t("customers.form.editTitle")}
      </h1>

      <Card className="px-5">
        <Stepper steps={steps} currentIndex={step} maxCompletedIndex={maxStepReached} />
      </Card>

      {step === 0 ? (
        <Card className="gap-4 px-5">
          {mode === "create" ? (
            <div className="space-y-2 px-1">
              <div className="flex items-center justify-between">
                <Label>{t("customers.detail.membersTitle", { count: fields.length })}</Label>
                <Button
                  type="button"
                  size="sm"
                  variant="outline"
                  disabled={fields.length >= 5}
                  title={fields.length >= 5 ? t("customers.form.maxMembersReached") : undefined}
                  onClick={() => append({ name: "", mobile: "" })}
                >
                  <Plus className="size-3.5" />
                  {t("customers.detail.addMember")}
                </Button>
              </div>
              {fields.length >= 5 ? <p className="text-xs text-text-muted">{t("customers.form.maxMembersReached")}</p> : null}
              <div className="space-y-2">
                {fields.map((field, index) => (
                  <MemberFieldRow
                    key={field.id}
                    index={index}
                    control={peopleForm.control}
                    register={peopleForm.register}
                    errors={peopleForm.formState.errors}
                    watch={peopleForm.watch}
                    orgId={orgId}
                    isPrimary={primaryIndex === index}
                    canRemove={fields.length > 1}
                    onSetPrimary={() => peopleForm.setValue("primaryIndex", index)}
                    onRemove={() => {
                      remove(index)
                      if (primaryIndex === index) peopleForm.setValue("primaryIndex", 0)
                      else if (primaryIndex > index) peopleForm.setValue("primaryIndex", primaryIndex - 1)
                    }}
                  />
                ))}
              </div>
              {peopleForm.formState.errors.members?.message ? (
                <p className="text-xs text-danger">{t(peopleForm.formState.errors.members.message)}</p>
              ) : null}
              <DuplicateContactWarning
                matches={dupWarning.data}
                isLoading={dupWarning.isFetching}
                confirmed={dupWarningConfirmed}
                onConfirmedChange={(next) => setConfirmedDupWarningKey(next ? dupWarningKey : null)}
              />
              <PreferredLanguageSelect
                id="new-customer-preferred-language"
                i18nPrefix="customers.form"
                value={(peopleForm.watch("preferredLanguage") || null) as "en" | "ta" | null}
                onChange={(next) => peopleForm.setValue("preferredLanguage", next ?? "")}
              />
              <div className="space-y-1">
                <Label htmlFor="new-customer-email">{t("customers.form.email")}</Label>
                <Input id="new-customer-email" type="email" placeholder={t("customers.form.emailPlaceholder")} {...peopleForm.register("email")} />
                {peopleForm.formState.errors.email ? <p className="text-xs text-danger">{t(peopleForm.formState.errors.email.message!)}</p> : null}
              </div>
              {/* Referral incentives — capture-at-creation only, never shown in edit mode. */}
              <ReferrerPicker
                id="new-customer-referred-by"
                orgId={orgId}
                label={t("customers.form.referredBy")}
                value={peopleForm.watch("referredByUserId") ?? ""}
                onChange={(next) => peopleForm.setValue("referredByUserId", next)}
              />
            </div>
          ) : (
            <>
              <div className="space-y-1">
                <Label htmlFor="edit-customer-email">{t("customers.form.email")}</Label>
                <div className="flex gap-2">
                  <Input id="edit-customer-email" type="email" value={editEmail} onChange={(e) => setEditEmail(e.target.value)} placeholder={t("customers.form.emailPlaceholder")} />
                  <Button
                    type="button"
                    size="sm"
                    variant="outline"
                    disabled={updateEmail.isPending || editEmail.trim().toLowerCase() === (existing.data!.email ?? "")}
                    onClick={() => updateEmail.mutate(editEmail, { onError: () => toast.error(t("common.actionFailed")) })}
                  >
                    {t("common.save")}
                  </Button>
                </div>
              </div>
              <FamilyMembersPanel orgId={orgId} customerId={id!} members={existing.data!.customer_members} customerProfession={existing.data!.profession} />
              <div className="border-t border-border pt-4">
                <WaterHouseholdPanel
                  customerId={id!}
                  orgId={orgId}
                  waterSource={existing.data!.water_source}
                  waterSourceOther={existing.data!.water_source_other}
                  waterTdsPpm={existing.data!.water_tds_ppm}
                  waterPh={existing.data!.water_ph}
                  healthCondition={existing.data!.health_condition}
                  familyMemberCount={existing.data!.customer_members.length}
                  canEdit={canEditWaterHousehold(profile?.role)}
                />
              </div>
            </>
          )}
        </Card>
      ) : step === 1 ? (
        <Card className="gap-4 px-5">
          {hasLegacyAddressOnly ? (
            <div className="space-y-1.5 px-1">
              <Label htmlFor="fullAddress">{t("customers.form.fullAddress")}</Label>
              <textarea
                id="fullAddress"
                rows={3}
                placeholder={t("customers.form.fullAddressPlaceholder")}
                aria-invalid={!!addressForm.formState.errors.fullAddress}
                className="w-full resize-none rounded-xl border border-input bg-surface px-3 py-2 text-sm text-text outline-none transition-colors focus-visible:border-ring focus-visible:ring-3 focus-visible:ring-ring/30"
                {...addressForm.register("fullAddress")}
              />
              {addressForm.formState.errors.fullAddress ? (
                <p className="text-xs text-danger">{t(addressForm.formState.errors.fullAddress.message!)}</p>
              ) : null}
            </div>
          ) : null}
          <div className="grid grid-cols-2 gap-3 px-1">
            <div className="space-y-1.5">
              <Label htmlFor="doorNo">{t("customers.form.doorNo")}</Label>
              <Input id="doorNo" {...addressForm.register("doorNo")} />
            </div>
            <div className="space-y-1.5">
              <Label htmlFor="plotNo">{t("customers.form.plotNo")}</Label>
              <Input id="plotNo" {...addressForm.register("plotNo")} />
            </div>
            <div className="col-span-2 space-y-1.5">
              <Label htmlFor="buildingName">{t("customers.form.buildingName")}</Label>
              <Input id="buildingName" {...addressForm.register("buildingName")} />
            </div>
            <div className="space-y-1.5">
              <Label htmlFor="streetCross">{t("customers.form.streetCross")}</Label>
              {/* Recently-used (org-wide): suggestions show on focus before typing, then narrow as you type. */}
              <Autocomplete
                id="streetCross"
                value={streetCross}
                onChange={(v) => addressForm.setValue("streetCross", v, { shouldValidate: true })}
                suggestions={streetCrossAutocomplete.data ?? []}
                loading={streetCrossAutocomplete.isFetching}
                getKey={(v) => v}
                getLabel={(v) => v}
                onSelect={(v) => addressForm.setValue("streetCross", v, { shouldValidate: true })}
                emptyMessage={t("common.noData")}
                openOnFocus
              />
            </div>
            <div className="space-y-1.5">
              <Label htmlFor="subArea">{t("customers.form.subArea")}</Label>
              <Autocomplete
                id="subArea"
                value={subArea}
                onChange={(v) => addressForm.setValue("subArea", v, { shouldValidate: true })}
                suggestions={subAreaAutocomplete.data ?? []}
                loading={subAreaAutocomplete.isFetching}
                getKey={(v) => v}
                getLabel={(v) => v}
                onSelect={(v) => addressForm.setValue("subArea", v, { shouldValidate: true })}
                emptyMessage={t("common.noData")}
                openOnFocus
              />
            </div>
            <div className="space-y-1.5">
              <Label htmlFor="area">{t("customers.form.area")}</Label>
              <Autocomplete
                id="area"
                value={area}
                onChange={(v) => addressForm.setValue("area", v, { shouldValidate: true })}
                suggestions={areaAutocomplete.data ?? []}
                loading={areaAutocomplete.isFetching}
                getKey={(a) => a}
                getLabel={(a) => a}
                onSelect={(a) => addressForm.setValue("area", a, { shouldValidate: true })}
                emptyMessage={t("common.noData")}
                openOnFocus
              />
              {addressForm.formState.errors.area ? (
                <p className="text-xs text-danger">{t(addressForm.formState.errors.area.message!)}</p>
              ) : null}
            </div>
            <div className="space-y-1.5">
              <Label htmlFor="landmark">{t("customers.form.landmark")}</Label>
              <Autocomplete
                id="landmark"
                value={landmark}
                onChange={(v) => addressForm.setValue("landmark", v, { shouldValidate: true })}
                suggestions={landmarkAutocomplete.data ?? []}
                loading={landmarkAutocomplete.isFetching}
                getKey={(v) => v}
                getLabel={(v) => v}
                onSelect={(v) => addressForm.setValue("landmark", v, { shouldValidate: true })}
                emptyMessage={t("common.noData")}
                openOnFocus
              />
            </div>
            <div className="space-y-1.5">
              <Label htmlFor="pincode">{t("customers.form.pincode")}</Label>
              {/* Suggests existing pincodes (recent-first, narrowed as you type) and
                  fills District/State from the picked one -- same "only fill if blank"
                  rule as the map's onAddressSelect below. */}
              <Autocomplete
                id="pincode"
                value={pincode}
                onChange={(v) => addressForm.setValue("pincode", v, { shouldValidate: true })}
                suggestions={pincodeSuggestions.data ?? []}
                loading={pincodeSuggestions.isFetching}
                getKey={(p) => p.pincode}
                getLabel={(p) => (p.area ? `${p.pincode} — ${p.area}, ${p.district ?? ""}`.replace(/,\s*$/, "") : p.pincode)}
                onSelect={(p) => {
                  addressForm.setValue("pincode", p.pincode, { shouldValidate: true })
                  if (!addressForm.getValues("district") && p.district) addressForm.setValue("district", p.district, { shouldValidate: true })
                  if (!addressForm.getValues("state") && p.state) addressForm.setValue("state", p.state, { shouldValidate: true })
                }}
                emptyMessage={t("common.noData")}
                openOnFocus
                maxLength={6}
                ariaInvalid={!!addressForm.formState.errors.pincode}
              />
              {addressForm.formState.errors.pincode ? (
                <p className="text-xs text-danger">{t(addressForm.formState.errors.pincode.message!)}</p>
              ) : null}
            </div>
            <div className="space-y-1.5">
              <Label htmlFor="district">{t("customers.form.district")}</Label>
              <Input id="district" {...addressForm.register("district")} />
            </div>
            <div className="space-y-1.5">
              <Label htmlFor="state">{t("customers.form.state")}</Label>
              <Input id="state" {...addressForm.register("state")} />
            </div>
            <div className="space-y-1.5">
              <Label htmlFor="zone">{t("customers.form.zone")}</Label>
              <Input id="zone" {...addressForm.register("zone")} />
            </div>
          </div>

          <div className="space-y-1.5 border-t border-border px-1 pt-3">
            <div className="flex items-center gap-2">
              <Label>{t("customers.form.map.title")}</Label>
              {lat != null && lng != null ? (
                <StatusDot tone="success" label={t("customers.form.map.pinned")} />
              ) : (
                <StatusDot tone="warning" label={t("customers.form.map.notPinned")} />
              )}
              {autoLocate.isPending && lat == null ? (
                <span className="flex items-center gap-1 text-xs text-text-muted">
                  <Loader2 className="size-3 animate-spin" />
                  {t("customers.form.map.autoLocating")}
                </span>
              ) : null}
            </div>
            <AddressMapPicker
              lat={addressForm.watch("lat")}
              lng={addressForm.watch("lng")}
              suggestedLat={suggestedPin?.lat}
              suggestedLng={suggestedPin?.lng}
              suggestedFormatted={suggestedPin?.formatted}
              suggestedPrecise={suggestedPin?.precise}
              onConfirm={({ lat: newLat, lng: newLng }) => {
                addressForm.setValue("lat", newLat, { shouldValidate: true })
                addressForm.setValue("lng", newLng, { shouldValidate: true })
                setSuggestedPin(null)
                confirmedLocationTextRef.current = autoLocateQuery
              }}
              onAddressSelect={(r) => {
                // Typing a full address into the map's own search box sorts
                // straight into the matching structured fields below, so
                // staff never have to type the same thing twice.
                if (!addressForm.getValues("streetCross") && r.route) {
                  addressForm.setValue("streetCross", r.route, { shouldValidate: true })
                }
                if (!addressForm.getValues("doorNo") && r.streetNumber) {
                  addressForm.setValue("doorNo", r.streetNumber, { shouldValidate: true })
                }
                if (!addressForm.getValues("area") && (r.suburb || r.city)) {
                  addressForm.setValue("area", r.suburb ?? r.city ?? "", { shouldValidate: true })
                }
                // Google's geocode result has no separate "zone" component --
                // same best-effort fallback (suburb) area itself uses above.
                if (!addressForm.getValues("zone") && r.suburb) {
                  addressForm.setValue("zone", r.suburb, { shouldValidate: true })
                }
                if (!addressForm.getValues("pincode") && r.postcode) {
                  addressForm.setValue("pincode", r.postcode, { shouldValidate: true })
                }
                if (!addressForm.getValues("district") && r.district) {
                  addressForm.setValue("district", r.district, { shouldValidate: true })
                }
                if (!addressForm.getValues("state") && r.state) {
                  addressForm.setValue("state", r.state, { shouldValidate: true })
                }
              }}
            />
            {lat == null && lng == null && !autoLocate.isPending && hasAddressText(addressForm.getValues()) ? (
              <p className="text-xs text-warning">
                {pinOptional ? t("customers.form.map.pinOptionalMasterNote") : t("customers.form.map.pinRequired")}
              </p>
            ) : null}
          </div>

          <div className="flex flex-wrap gap-4 border-t border-border px-1 pt-3">
            <div className="space-y-1.5">
              <Label>{t("customers.form.addressType")}</Label>
              <div className="flex gap-1 rounded-full bg-surface-alt p-1">
                {(["residential", "commercial"] as const).map((v) => (
                  <SegButton key={v} active={addressForm.watch("addressType") === v} onClick={() => addressForm.setValue("addressType", v)}>
                    {t(`customers.form.${v}`)}
                  </SegButton>
                ))}
              </div>
            </div>
            <div className="space-y-1.5">
              <Label>{t("customers.form.ownership")}</Label>
              <div className="flex gap-1 rounded-full bg-surface-alt p-1">
                {(["own", "rental"] as const).map((v) => (
                  <SegButton key={v} active={addressForm.watch("ownership") === v} onClick={() => addressForm.setValue("ownership", v)}>
                    {t(`customers.form.${v}`)}
                  </SegButton>
                ))}
              </div>
            </div>
          </div>
        </Card>
      ) : (
        <Card className="gap-4 px-5">
          <div className="flex items-center justify-between px-1">
            <Label>{t("customers.form.water.title")}</Label>
            <Button type="button" size="sm" variant="outline" onClick={() => setWaterEditing((v) => !v)}>
              <Pencil className="size-3.5" />
              {t("customers.form.water.edit")}
            </Button>
          </div>
          {waterEditing ? (
            <div className="space-y-3 px-1">
              <div className="space-y-1.5">
                <Label htmlFor="waterSource">{t("customers.form.water.waterSource")}</Label>
                <Input id="waterSource" placeholder={t("customers.form.water.waterSourcePlaceholder")} {...addressForm.register("waterSource")} />
              </div>
              <div className="grid grid-cols-2 gap-3">
                <div className="space-y-1.5">
                  <Label htmlFor="waterTds">{t("customers.form.water.waterTds")}</Label>
                  <Input
                    id="waterTds"
                    type="number"
                    placeholder={t("customers.form.water.valuePlaceholder")}
                    {...addressForm.register("waterTds", { setValueAs: (v) => (v === "" || v == null ? undefined : Number(v)) })}
                  />
                </div>
                <div className="space-y-1.5">
                  <Label htmlFor="waterPh">{t("customers.form.water.waterPh")}</Label>
                  <Input
                    id="waterPh"
                    type="number"
                    step="0.1"
                    placeholder={t("customers.form.water.valuePlaceholder")}
                    {...addressForm.register("waterPh", { setValueAs: (v) => (v === "" || v == null ? undefined : Number(v)) })}
                  />
                </div>
              </div>
              <div className="space-y-1.5">
                <Label htmlFor="healthCondition">{t("customers.form.water.healthCondition")}</Label>
                <Input
                  id="healthCondition"
                  placeholder={t("customers.form.water.healthConditionPlaceholder")}
                  {...addressForm.register("healthCondition")}
                />
              </div>
            </div>
          ) : (
            <div className="divide-y divide-border px-1">
              {(
                [
                  [t("customers.form.water.waterSource"), addressForm.watch("waterSource")],
                  [t("customers.form.water.waterTds"), addressForm.watch("waterTds")],
                  [t("customers.form.water.waterPh"), addressForm.watch("waterPh")],
                  [t("customers.form.water.healthCondition"), addressForm.watch("healthCondition")],
                ] as const
              ).map(([label, value]) => (
                <div key={label} className="flex items-center justify-between py-2.5 text-sm">
                  <span className="text-text-muted">{label}</span>
                  <span className="font-medium text-text">{value || value === 0 ? value : "—"}</span>
                </div>
              ))}
              <div className="flex items-center justify-between py-2.5 text-sm">
                <span className="text-text-muted">{t("customers.form.water.familyMembers")}</span>
                <span className="font-medium text-text">{fields.length}</span>
              </div>
            </div>
          )}
        </Card>
      )}

      {saveError ? <p className="rounded-xl bg-danger/10 px-3.5 py-2.5 text-sm text-danger">{saveError.message}</p> : null}

      <div className="flex justify-between">
        <Button type="button" variant="outline" onClick={() => (step === 0 ? navigate(-1) : setStep(step - 1))}>
          {step === 0 ? t("common.cancel") : t("customers.form.back")}
        </Button>
        {step === 0 ? (
          <Button type="button" onClick={handleNext}>
            {t("customers.form.next")}
          </Button>
        ) : step === 1 ? (
          <Button
            type="button"
            onClick={handleAddressNext}
            disabled={lat == null && lng == null && hasAddressText(addressForm.getValues())}
          >
            {t("customers.form.next")}
          </Button>
        ) : (
          <Button
            type="button"
            onClick={handleSaveAndFinish}
            disabled={isSaving || (mode === "create" && !canSubmitWithWarning(dupWarning.data, dupWarningConfirmed))}
          >
            {isSaving ? <Loader2 className="size-4 animate-spin" /> : t("common.save")}
          </Button>
        )}
      </div>
    </div>
  )
}
