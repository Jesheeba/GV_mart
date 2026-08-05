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
import { AddressMapPicker } from "@/components/shared/AddressMapPicker"
import { FullPageError, FullPageLoader } from "@/components/shared/FullPageLoader"
import { useToast } from "@/components/ui/toast-context"
import { FamilyMembersPanel } from "./FamilyMembersPanel"
import {
  addressStepSchema,
  peopleStepSchema,
  FAMILY_RELATIONS,
  type AddressStepInput,
  type PeopleStepInput,
} from "@/lib/validation/customer"
import { useProfile } from "@/hooks/useProfile"
import { useDebouncedValue } from "@/hooks/useDebouncedValue"
import { useGeocodeAddress } from "@/hooks/useMaps"
import { isPreciseGeocodeResult } from "@/services/maps"
import { getPrimaryAddressId, setAddressZone } from "@/services/customers"
import {
  useAreaAutocomplete,
  useCreateCustomer,
  useCustomer,
  useMobileDuplicateCheck,
  usePincodeLookup,
  useUpdateCustomerProfession,
  useUpsertPrimaryAddress,
} from "@/hooks/useCustomers"

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

  const existing = useCustomer(mode === "edit" ? id : undefined)
  const [step, setStep] = useState(0)
  // Only ever grows — tracks the furthest step reached so navigating back
  // (which decreases `step`) doesn't make already-completed steps lose their
  // checkmark in the Stepper below. See Stepper's `maxCompletedIndex` doc.
  const [maxStepReached, setMaxStepReached] = useState(0)

  const peopleForm = useForm<PeopleStepInput>({
    resolver: zodResolver(peopleStepSchema),
    mode: "onChange",
    defaultValues: { members: [{ name: "", mobile: "" }], primaryIndex: 0, profession: "" },
  })
  const { fields, append, remove } = useFieldArray({ control: peopleForm.control, name: "members" })
  const primaryIndex = peopleForm.watch("primaryIndex")

  const addressForm = useForm<AddressStepInput>({
    resolver: zodResolver(addressStepSchema),
    mode: "onChange",
    defaultValues: {
      doorNo: "",
      flatNo: "",
      streetCross: "",
      area: "",
      pincode: "",
      landmark: "",
      district: "",
      state: "",
      zone: "",
      addressType: "residential",
      ownership: "own",
      lat: undefined,
      lng: undefined,
    },
  })
  const doorNo = addressForm.watch("doorNo")
  const flatNo = addressForm.watch("flatNo")
  const area = addressForm.watch("area")
  const pincode = addressForm.watch("pincode")
  const streetCross = addressForm.watch("streetCross")
  const landmark = addressForm.watch("landmark")
  const district = addressForm.watch("district")
  const state = addressForm.watch("state")
  const lat = addressForm.watch("lat")
  const lng = addressForm.watch("lng")
  const areaAutocomplete = useAreaAutocomplete(orgId, area)
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
  // customer's actual location"): this used to (a) omit doorNo/flatNo/
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
  const autoLocateQuery = [doorNo, flatNo, streetCross, area, landmark, pincode, district, state].filter(Boolean).join(", ")
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
      const primary = existing.data.addresses.find((a) => a.is_primary) ?? existing.data.addresses[0]
      if (primary) {
        addressForm.reset({
          doorNo: primary.door_no ?? "",
          flatNo: primary.flat_no ?? "",
          streetCross: primary.street_cross ?? "",
          area: primary.area ?? "",
          pincode: primary.pincode ?? "",
          landmark: primary.landmark ?? "",
          district: primary.district ?? "",
          state: primary.state ?? "",
          zone: primary.zone ?? "",
          addressType: primary.address_type,
          ownership: primary.ownership,
          lat: primary.lat ?? undefined,
          lng: primary.lng ?? undefined,
        })
        confirmedLocationTextRef.current = [
          primary.door_no,
          primary.flat_no,
          primary.street_cross,
          primary.area,
          primary.landmark,
          primary.pincode,
          primary.district,
          primary.state,
        ]
          .filter(Boolean)
          .join(", ")
      }
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [mode, existing.data])

  const createCustomer = useCreateCustomer()
  const updateProfession = useUpdateCustomerProfession(id ?? "")
  const upsertAddress = useUpsertPrimaryAddress(orgId, id ?? "")

  if (mode === "edit" && existing.isLoading) return <FullPageLoader label={t("common.loading")} />
  if (mode === "edit" && (existing.isError || !existing.data)) {
    return <FullPageError message={t("customers.error.loadFailed")} onRetry={() => existing.refetch()} retryLabel={t("common.retry")} />
  }

  const steps = [
    { key: "people", label: t("customers.form.stepPeople") },
    { key: "address", label: t("customers.form.stepAddress") },
  ]

  async function handleNext() {
    if (mode === "create") {
      const valid = await peopleForm.trigger()
      if (!valid) return
    }
    setStep(1)
    setMaxStepReached((m) => Math.max(m, 1))
  }

  async function handleSaveAndFinish() {
    const valid = await addressForm.trigger()
    if (!valid) return
    const addressValues = addressForm.getValues()

    if (mode === "create") {
      const peopleValues = peopleForm.getValues()
      const newId = await createCustomer.mutateAsync({
        orgId: orgId!,
        profession: peopleValues.profession,
        members: peopleValues.members.map((m, i) => ({
          name: m.name,
          mobile: m.mobile,
          isPrimary: i === peopleValues.primaryIndex,
          relation: i === peopleValues.primaryIndex ? undefined : m.relation,
        })),
        address: {
          doorNo: addressValues.doorNo,
          flatNo: addressValues.flatNo,
          streetCross: addressValues.streetCross,
          area: addressValues.area,
          pincode: addressValues.pincode,
          landmark: addressValues.landmark,
          district: addressValues.district,
          state: addressValues.state,
          addressType: addressValues.addressType,
          ownership: addressValues.ownership,
          lat: addressValues.lat,
          lng: addressValues.lng,
        },
      })
      // create_customer_with_details (RPC) doesn't accept a zone — set it as
      // a small direct follow-up write on the primary address it just created.
      // The customer itself is already created at this point, so a failure
      // here shouldn't block navigation — just warn so it can be re-entered
      // via edit.
      if (addressValues.zone?.trim()) {
        try {
          const primaryAddressId = await getPrimaryAddressId(newId)
          await setAddressZone(primaryAddressId, addressValues.zone.trim())
        } catch {
          toast.error(t("common.actionFailed"))
        }
      }
      navigate(`/admin/customers/${newId}`)
      return
    }

    // edit mode
    const profession = peopleForm.getValues("profession")
    await updateProfession.mutateAsync(profession ?? "")
    const existingAddressId = existing.data!.addresses.find((a) => a.is_primary)?.id ?? existing.data!.addresses[0]?.id ?? null
    await upsertAddress.mutateAsync({ existingAddressId, patch: addressValues })
    navigate(`/admin/customers/${id}`)
  }

  const isSaving = createCustomer.isPending || updateProfession.isPending || upsertAddress.isPending
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
          <div className="space-y-1.5 px-1">
            <Label htmlFor="profession">{t("customers.form.profession")}</Label>
            <Input id="profession" placeholder={t("customers.form.professionPlaceholder")} {...peopleForm.register("profession")} />
          </div>

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
            </div>
          ) : (
            <FamilyMembersPanel orgId={orgId} customerId={id!} members={existing.data!.customer_members} />
          )}
        </Card>
      ) : (
        <Card className="gap-4 px-5">
          <div className="grid grid-cols-2 gap-3 px-1">
            <div className="space-y-1.5">
              <Label htmlFor="doorNo">{t("customers.form.doorNo")}</Label>
              <Input id="doorNo" aria-invalid={!!addressForm.formState.errors.doorNo} {...addressForm.register("doorNo")} />
              {addressForm.formState.errors.doorNo ? (
                <p className="text-xs text-danger">{t(addressForm.formState.errors.doorNo.message!)}</p>
              ) : null}
            </div>
            <div className="space-y-1.5">
              <Label htmlFor="flatNo">{t("customers.form.flatNo")}</Label>
              <Input id="flatNo" {...addressForm.register("flatNo")} />
            </div>
            <div className="space-y-1.5">
              <Label htmlFor="streetCross">{t("customers.form.streetCross")}</Label>
              <Input id="streetCross" {...addressForm.register("streetCross")} />
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
              />
              {addressForm.formState.errors.area ? (
                <p className="text-xs text-danger">{t(addressForm.formState.errors.area.message!)}</p>
              ) : null}
            </div>
            <div className="space-y-1.5">
              <Label htmlFor="pincode">{t("customers.form.pincode")}</Label>
              <Input id="pincode" maxLength={6} aria-invalid={!!addressForm.formState.errors.pincode} {...addressForm.register("pincode")} />
              {addressForm.formState.errors.pincode ? (
                <p className="text-xs text-danger">{t(addressForm.formState.errors.pincode.message!)}</p>
              ) : null}
            </div>
            <div className="space-y-1.5">
              <Label htmlFor="landmark">{t("customers.form.landmark")}</Label>
              <Input id="landmark" {...addressForm.register("landmark")} />
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
            <div className="flex items-center gap-1.5">
              <Label>{t("customers.form.map.title")}</Label>
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
                if (!addressForm.getValues("area") && (r.suburb || r.city)) {
                  addressForm.setValue("area", r.suburb ?? r.city ?? "", { shouldValidate: true })
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
            {lat == null && lng == null && !autoLocate.isPending ? (
              <p className="text-xs text-warning">{t("customers.form.map.pinRequired")}</p>
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
      )}

      {saveError ? <p className="rounded-xl bg-danger/10 px-3.5 py-2.5 text-sm text-danger">{saveError.message}</p> : null}

      <div className="flex justify-between">
        <Button type="button" variant="outline" onClick={() => (step === 0 ? navigate(-1) : setStep(0))}>
          {step === 0 ? t("common.cancel") : t("customers.form.back")}
        </Button>
        {step === 0 ? (
          <Button type="button" onClick={handleNext}>
            {t("customers.form.next")}
          </Button>
        ) : (
          <Button type="button" onClick={handleSaveAndFinish} disabled={isSaving}>
            {isSaving ? <Loader2 className="size-4 animate-spin" /> : t("common.save")}
          </Button>
        )}
      </div>
    </div>
  )
}
