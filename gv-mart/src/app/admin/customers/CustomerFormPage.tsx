import { useEffect, useRef, useState } from "react"
import { useTranslation } from "react-i18next"
import { useNavigate, useParams } from "react-router-dom"
import { useFieldArray, useForm, type Control, type FieldErrors, type UseFormRegister, type UseFormWatch } from "react-hook-form"
import { zodResolver } from "@hookform/resolvers/zod"
import { Loader2, Plus, Star, Trash2 } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { Card } from "@/components/ui/card"
import { Stepper } from "@/components/shared/Stepper"
import { SegButton } from "@/components/shared/SegButton"
import { Autocomplete } from "@/components/shared/Autocomplete"
import { VerifiedLocationCard } from "./VerifiedLocationCard"
import { AddressMapPicker } from "@/components/shared/AddressMapPicker"
import { ReferrerField } from "@/components/shared/ReferrerField"
import { EMPTY_REFERRER, type ReferrerValue } from "@/lib/referrer"
import { FullPageError, FullPageLoader } from "@/components/shared/FullPageLoader"
import { useToast } from "@/components/ui/toast-context"
import { PreferredLanguageSelect } from "@/components/shared/PreferredLanguageSelect"
import { StatusDot } from "@/components/shared/StatusDot"
import { FamilyMembersPanel } from "./FamilyMembersPanel"
import {
  WaterHouseholdFields,
  checkFollowUpDate,
  isWaterPatchEmpty,
  isWaterProfileDirty,
  waterFormDefaults,
  waterFormToPatch,
  waterValuesFromCustomer,
} from "./WaterHouseholdPanel"
import {
  addressStepSchema,
  peopleStepSchema,
  canSkipAddressPin,
  FAMILY_RELATIONS,
  waterProfileSchema,
  type WaterProfileInput,
  hasAddressDetails,
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
  setAddressZone,
  setCustomerPreferredLanguage,
  updateCustomerEmail,
  saveWaterHousehold,
} from "@/services/customers"
import { resolveFullAddress, splitAddressForForm, type StructuredAddressFields } from "@/lib/address"
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
  useCustomerWaterFollowup,
  useSaveWaterHousehold,
  useUpsertPrimaryAddress,
} from "@/hooks/useCustomers"
import { canSubmitWithWarning, duplicateWarningKey } from "@/lib/duplicateContactWarning"
import { DuplicateContactWarning } from "@/components/shared/DuplicateContactWarning"
import { guardReentry } from "@/lib/async-guard"
import { FIELD_W } from "@/lib/fieldWidth"
import { cn, focusChoice } from "@/lib/utils"

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
        <div className={cn(FIELD_W.mobile, "shrink-0 space-y-1")}>
          <Input
            placeholder={t("customers.form.memberMobile")}
            inputMode="numeric"
            maxLength={10}
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
            className="h-10 rounded-xl border border-border bg-surface px-3 text-sm text-text outline-none"
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

/** The address text a map pin belongs to -- what auto-locate geocodes and what a confirmed pin is compared against. */
function locationText(v: StructuredAddressFields & { fullAddress?: string; pincode?: string; district?: string; state?: string }) {
  return [resolveFullAddress(v), v.pincode, v.district, v.state].filter(Boolean).join(", ")
}

// Compact field sizing for every step card (Autocomplete renders the same Input).
const COMPACT_CARD = "gap-3 px-4 [&_input]:h-8 [&_input]:px-2.5 [&_label]:text-xs [&_select]:h-8"

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
  // in create mode, against the primary member's own mobile + email (the two identifiers
  // find_duplicate_contacts matches on). The primary member's row is the ONE place the account
  // email is typed (sweep 2026-11-26: a second "email" box saved somewhere else).
  const primaryMobile = peopleForm.watch(`members.${primaryIndex}.mobile`) ?? ""
  const topEmail = peopleForm.watch(`members.${primaryIndex}.email`) ?? ""
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
      // Unchosen on a new customer (choice-no-preselect); the edit reset below loads the saved values.
      addressType: undefined,
      ownership: undefined,
      lat: undefined,
      lng: undefined,
    },
  })
  // Water & household step: the customer's one water profile (customers columns) — the same
  // fields and the same row the detail page's Water & household tab edits.
  const waterForm = useForm<WaterProfileInput>({ resolver: zodResolver(waterProfileSchema), mode: "onChange", defaultValues: waterFormDefaults() })
  const saveWater = useSaveWaterHousehold()
  // Edit mode: the open follow-up task's due date is the follow-up date (single store — see the feature doc).
  const followup = useCustomerWaterFollowup(mode === "edit" ? id : undefined)
  const savedFollowUpDate = followup.data?.dueDate ?? null
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
  // Each "recently used" query only turns on once its own field is actually
  // focused -- all 5 firing together the moment the Address step mounts was
  // 5 extra DB round-trips competing with everything else on page load,
  // before anyone had even looked at most of these fields.
  const [touchedFields, setTouchedFields] = useState<Record<string, boolean>>({})
  const touch = (field: string) => setTouchedFields((f) => (f[field] ? f : { ...f, [field]: true }))
  const areaAutocomplete = useAreaAutocomplete(orgId, area, touchedFields.area)
  const landmarkAutocomplete = useLandmarkAutocomplete(orgId, landmark, touchedFields.landmark)
  const streetCrossAutocomplete = useStreetCrossAutocomplete(orgId, streetCross, touchedFields.streetCross)
  const subAreaAutocomplete = useSubAreaAutocomplete(orgId, subArea, touchedFields.subArea)
  const pincodeSuggestions = usePincodeSuggestions(orgId, pincode, touchedFields.pincode)
  const pincodeLookup = usePincodeLookup(orgId, pincode)
  const autoLocate = useGeocodeAddress()
  // Arrival location lock: the primary address's pin was verified on site by a
  // technician — the map is read-only and nothing here may move or clear it.
  const editedAddress = mode === "edit" ? (existing.data?.addresses.find((a) => a.is_primary) ?? existing.data?.addresses[0]) : undefined
  const lockedAddress = editedAddress?.location_verified_at && editedAddress.lat != null && editedAddress.lng != null ? editedAddress : null
  const locationLocked = !!lockedAddress

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
  const autoLocateQuery = locationText({ doorNo, plotNo, buildingName, streetCross, subArea, area, landmark, fullAddress: legacyFullAddress, pincode, district, state })
  const debouncedAutoLocateQuery = useDebouncedValue(autoLocateQuery, 800)
  const [suggestedPin, setSuggestedPin] = useState<{ lat: number; lng: number; formatted: string; precise: boolean } | null>(null)
  useEffect(() => {
    if (locationLocked || (lat != null && lng != null)) return
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
  }, [debouncedAutoLocateQuery, pincode, lat, lng, locationLocked])

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
  // The map search box mirrors the address typed above, so staff never type it twice.
  const [mapQuery, setMapQuery] = useState(autoLocateQuery)
  useEffect(() => setMapQuery(autoLocateQuery), [autoLocateQuery])
  useEffect(() => {
    if (locationLocked || (lat == null && lng == null) || autoLocateQuery === confirmedLocationTextRef.current) return
    addressForm.setValue("lat", undefined, { shouldValidate: true })
    addressForm.setValue("lng", undefined, { shouldValidate: true })
    setSuggestedPin(null)
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [autoLocateQuery])

  useEffect(() => {
    if (mode === "edit" && existing.data) {
      peopleForm.reset({ members: [], primaryIndex: 0, profession: existing.data.profession ?? "" })
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
        })
        // Same text locationText() builds for the loaded values, so a saved pin isn't cleared on load.
        confirmedLocationTextRef.current = locationText({
          ...split,
          fullAddress: split.legacyFullAddress,
          pincode: primary.pincode ?? "",
          district: primary.district ?? "",
          state: primary.state ?? "",
        })
      }
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [mode, existing.data])

  useEffect(() => {
    if (mode === "edit" && existing.data && followup.isFetched) {
      waterForm.reset(waterFormDefaults(waterValuesFromCustomer(existing.data), followup.data?.dueDate ?? null))
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [mode, existing.data, followup.data, followup.isFetched])

  const createCustomer = useCreateCustomer()
  const [referrer, setReferrer] = useState<ReferrerValue>(EMPTY_REFERRER)
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

  if (mode === "edit" && (existing.isLoading || followup.isLoading)) return <FullPageLoader label={t("common.loading")} />
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

  // Type/ownership live on the address step: send staff back there and focus the first missing choice.
  function focusMissingAddressChoice() {
    const id = addressForm.getFieldState("addressType").error
      ? "address-type-group"
      : addressForm.getFieldState("ownership").error
        ? "address-ownership-group"
        : null
    if (!id) return false
    setStep(1)
    requestAnimationFrame(() => focusChoice(id))
    return true
  }

  async function handleAddressNext() {
    const valid = await addressForm.trigger(["pincode", "addressType", "ownership"])
    if (!valid) {
      focusMissingAddressChoice()
      return
    }
    setStep(2)
    setMaxStepReached((m) => Math.max(m, 2))
  }

  async function handleSaveAndFinish() {
    await guardReentry(savingRef, async () => {
      await handleSaveAndFinishInner()
    })
  }

  async function handleSaveAndFinishInner() {
    const [valid, waterValid] = await Promise.all([addressForm.trigger(), waterForm.trigger()])
    if (!valid) {
      focusMissingAddressChoice()
      return
    }
    if (!waterValid || !checkFollowUpDate(waterForm, savedFollowUpDate)) return
    const addressValues = addressForm.getValues()
    const waterPatch = waterFormToPatch(waterForm.getValues())
    // Structured fields are the source of truth the moment any is filled;
    // only a customer that still has nothing but the legacy fallback box
    // keeps that text as full_address. See composeFullAddress in src/lib/address.ts.
    const composedFullAddress = resolveFullAddress(addressValues)

    if (mode === "create") {
      const peopleValues = peopleForm.getValues()
      const referredByUserId = peopleValues.referredByUserId || undefined
      const newId = await createCustomer.mutateAsync({
        orgId: orgId!,
        // The primary member's own profession becomes the customer's (the RPC also falls back to it).
        profession: peopleValues.members[peopleValues.primaryIndex]?.profession?.trim() || undefined,
        referredByUserId,
        referredByCustomerId: referrer.kind === "customer" ? referrer.customerId || undefined : undefined,
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
      // create_customer_with_details stores member emails but not the account email (customers.email,
      // used for Google sign-in matching) -- set it from the primary member, same follow-up write shape
      // as the language field above (updateCustomerEmail normalizes trim+lowercase). From then on the
      // DB keeps the two in step (20261216120000_primary_member_sync.sql).
      const primaryEmail = peopleValues.members[peopleValues.primaryIndex]?.email?.trim()
      if (primaryEmail) {
        try {
          await updateCustomerEmail(newId, primaryEmail)
        } catch {
          toast.error(t("common.actionFailed"))
        }
      }
      // create_customer_with_details (RPC) doesn't accept a zone — set it as
      // a small direct follow-up write on the primary address it just created.
      // The customer itself is already created at this point, so a failure
      // here shouldn't block navigation — just warn so it can be re-entered
      // via edit.
      if (addressValues.zone?.trim() && hasAddressDetails(addressValues)) {
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
      if (hasStructuredFields && hasAddressDetails(addressValues)) {
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
      // Water & household step — the create RPC has no slot for these; same small follow-up
      // write as the language field above, on the customers row that now exists.
      const followUpDate = waterForm.getValues("followUpDate") || null
      if (!isWaterPatchEmpty(waterPatch) || followUpDate) {
        try {
          await saveWaterHousehold({
            customerId: newId,
            patch: waterPatch,
            profileDirty: !isWaterPatchEmpty(waterPatch),
            followUpDate,
            savedFollowUpDate: null,
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
    if (existingAddressId || hasAddressDetails(addressValues)) {
      await upsertAddress.mutateAsync({ existingAddressId, patch: { ...addressValues, fullAddress: composedFullAddress, keepLocation: locationLocked } })
    }
    await saveWater.mutateAsync({
      customerId: id!,
      patch: waterPatch,
      profileDirty: isWaterProfileDirty(waterForm.formState.dirtyFields),
      followUpDate: waterForm.getValues("followUpDate") || null,
      savedFollowUpDate,
    })
    navigate(`/admin/customers/${id}`)
  }

  const isSaving = createCustomer.isPending || upsertAddress.isPending || saveWater.isPending
  const saveError = (createCustomer.error ?? upsertAddress.error ?? saveWater.error) as Error | null

  return (
    <div className="mx-auto max-w-xl space-y-3 pt-2">
      <h1 className="text-2xl font-bold text-text">
        {mode === "create" ? t("customers.form.createTitle") : t("customers.form.editTitle")}
      </h1>

      <Card className="px-5">
        <Stepper steps={steps} currentIndex={step} maxCompletedIndex={maxStepReached} />
      </Card>

      {step === 0 ? (
        <Card className={COMPACT_CARD}>
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
              {/* Referral incentives — capture-at-creation only, never shown in edit mode. */}
              <ReferrerField
                idPrefix="new-customer-referred-by"
                orgId={orgId}
                label={t("customers.form.referredBy")}
                // No "someone else": a customer record only links a technician/staff profile or another customer.
                kinds={["none", "technician", "staff", "customer"]}
                value={referrer}
                onChange={(next) => {
                  setReferrer(next)
                  peopleForm.setValue("referredByUserId", next.kind === "technician" || next.kind === "staff" ? next.userId : "")
                }}
              />
            </div>
          ) : (
            <FamilyMembersPanel orgId={orgId} customerId={id!} members={existing.data!.customer_members} customerProfession={existing.data!.profession} />
          )}
        </Card>
      ) : step === 1 ? (
        <Card className={COMPACT_CARD}>
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
            <div className="col-span-2 grid grid-cols-3 gap-3">
              <div className="space-y-1.5">
                <Label htmlFor="doorNo">{t("customers.form.doorNo")}</Label>
                <Input id="doorNo" {...addressForm.register("doorNo")} />
              </div>
              <div className="space-y-1.5">
                <Label htmlFor="plotNo">{t("customers.form.plotNo")}</Label>
                <Input id="plotNo" {...addressForm.register("plotNo")} />
              </div>
              <div className="space-y-1.5">
                <Label htmlFor="buildingName">{t("customers.form.buildingName")}</Label>
                <Input id="buildingName" {...addressForm.register("buildingName")} />
              </div>
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
                onFocus={() => touch("streetCross")}
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
                onFocus={() => touch("subArea")}
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
                onFocus={() => touch("area")}
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
                onFocus={() => touch("landmark")}
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
                onFocus={() => touch("pincode")}
                maxLength={6}
                inputMode="numeric"
                inputClassName={FIELD_W.pincode}
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
            {lockedAddress ? (
              <VerifiedLocationCard
                customerId={id!}
                addressId={lockedAddress.id}
                lat={lockedAddress.lat!}
                lng={lockedAddress.lng!}
                verifiedAt={lockedAddress.location_verified_at!}
                verifiedBy={lockedAddress.location_verified_by}
                canReset={profile?.role === "master"}
              />
            ) : (
            <>
            <AddressMapPicker
              lat={addressForm.watch("lat")}
              lng={addressForm.watch("lng")}
              query={mapQuery}
              onQueryChange={setMapQuery}
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
                // The pin was confirmed (onConfirm) before these blanks were
                // filled -- re-snapshot so the fill isn't mistaken for an
                // address edit that clears the pin just picked.
                confirmedLocationTextRef.current = locationText(addressForm.getValues())
              }}
            />
            {lat == null && lng == null && !autoLocate.isPending && hasAddressDetails(addressForm.getValues()) ? (
              <p className="text-xs text-warning">
                {pinOptional ? t("customers.form.map.pinOptionalMasterNote") : t("customers.form.map.pinRequired")}
              </p>
            ) : null}
            </>
            )}
          </div>

          <div className="flex flex-wrap gap-4 border-t border-border px-1 pt-3">
            <div className="space-y-1.5">
              <Label id="address-type-label">{t("customers.form.addressType")}</Label>
              <div
                id="address-type-group"
                role="group"
                aria-labelledby="address-type-label"
                aria-describedby={addressForm.formState.errors.addressType ? "address-type-error" : undefined}
                className="flex gap-1 rounded-full bg-surface-alt p-1"
              >
                {(["residential", "commercial"] as const).map((v) => (
                  <SegButton key={v} active={addressForm.watch("addressType") === v} onClick={() => addressForm.setValue("addressType", v, { shouldValidate: true })}>
                    {t(`customers.form.${v}`)}
                  </SegButton>
                ))}
              </div>
              {addressForm.formState.errors.addressType ? (
                <p id="address-type-error" role="alert" className="text-xs text-danger">{t(addressForm.formState.errors.addressType.message!)}</p>
              ) : null}
            </div>
            <div className="space-y-1.5">
              <Label id="address-ownership-label">{t("customers.form.ownership")}</Label>
              <div
                id="address-ownership-group"
                role="group"
                aria-labelledby="address-ownership-label"
                aria-describedby={addressForm.formState.errors.ownership ? "address-ownership-error" : undefined}
                className="flex gap-1 rounded-full bg-surface-alt p-1"
              >
                {(["own", "rental"] as const).map((v) => (
                  <SegButton key={v} active={addressForm.watch("ownership") === v} onClick={() => addressForm.setValue("ownership", v, { shouldValidate: true })}>
                    {t(`customers.form.${v}`)}
                  </SegButton>
                ))}
              </div>
              {addressForm.formState.errors.ownership ? (
                <p id="address-ownership-error" role="alert" className="text-xs text-danger">{t(addressForm.formState.errors.ownership.message!)}</p>
              ) : null}
            </div>
          </div>
        </Card>
      ) : (
        <Card className={COMPACT_CARD}>
          <h2 className="px-1 text-base font-semibold text-text">{t("customers.detail.waterHouseholdTitle")}</h2>
          <div className="px-1">
            <WaterHouseholdFields form={waterForm} />
          </div>
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
            disabled={!pinOptional && lat == null && lng == null && hasAddressDetails(addressForm.getValues())}
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
