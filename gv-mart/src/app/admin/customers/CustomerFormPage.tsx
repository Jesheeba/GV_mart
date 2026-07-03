import { useEffect, useState } from "react"
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
import { Autocomplete } from "@/components/shared/Autocomplete"
import { FullPageError, FullPageLoader } from "@/components/shared/FullPageLoader"
import { FamilyMembersPanel } from "./FamilyMembersPanel"
import {
  addressStepSchema,
  peopleStepSchema,
  type AddressStepInput,
  type PeopleStepInput,
} from "@/lib/validation/customer"
import { useProfile } from "@/hooks/useProfile"
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
        <div className="flex items-center gap-1 pt-1">
          <Button type="button" size="icon-xs" variant={isPrimary ? "accent" : "ghost"} title={t("customers.detail.setPrimary")} onClick={onSetPrimary}>
            <Star className={isPrimary ? "size-3.5 fill-current" : "size-3.5"} />
          </Button>
          {canRemove ? (
            <Button type="button" size="icon-xs" variant="ghost" title={t("customers.detail.remove")} onClick={onRemove}>
              <Trash2 className="size-3.5 text-danger" />
            </Button>
          ) : null}
        </div>
      </div>
    </div>
  )
}

export function CustomerFormPage() {
  const { t } = useTranslation()
  const navigate = useNavigate()
  const { id } = useParams<{ id?: string }>()
  const mode: "create" | "edit" = id ? "edit" : "create"
  const { data: profile } = useProfile()
  const orgId = profile?.org_id

  const existing = useCustomer(mode === "edit" ? id : undefined)
  const [step, setStep] = useState(0)

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
      addressType: "residential",
      ownership: "own",
    },
  })
  const area = addressForm.watch("area")
  const pincode = addressForm.watch("pincode")
  const areaAutocomplete = useAreaAutocomplete(orgId, area)
  const pincodeLookup = usePincodeLookup(orgId, pincode)

  useEffect(() => {
    if (pincodeLookup.data && !addressForm.getValues("district")) {
      addressForm.setValue("district", pincodeLookup.data.district ?? "")
      addressForm.setValue("state", pincodeLookup.data.state ?? "")
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [pincodeLookup.data])

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
          addressType: primary.address_type,
          ownership: primary.ownership,
        })
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
        members: peopleValues.members.map((m, i) => ({ name: m.name, mobile: m.mobile, isPrimary: i === peopleValues.primaryIndex })),
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
        },
      })
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

      <Card>
        <Stepper steps={steps} currentIndex={step} />
      </Card>

      {step === 0 ? (
        <Card className="gap-4">
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
        <Card className="gap-4">
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
          </div>

          <div className="flex flex-wrap gap-4 border-t border-border px-1 pt-3">
            <div className="space-y-1.5">
              <Label>{t("customers.form.addressType")}</Label>
              <div className="flex gap-1 rounded-full bg-surface-alt p-1">
                {(["residential", "commercial"] as const).map((v) => (
                  <button
                    key={v}
                    type="button"
                    onClick={() => addressForm.setValue("addressType", v)}
                    className={`rounded-full px-3 py-1.5 text-sm font-medium transition-colors ${
                      addressForm.watch("addressType") === v ? "bg-ink text-white" : "text-text-muted"
                    }`}
                  >
                    {t(`customers.form.${v}`)}
                  </button>
                ))}
              </div>
            </div>
            <div className="space-y-1.5">
              <Label>{t("customers.form.ownership")}</Label>
              <div className="flex gap-1 rounded-full bg-surface-alt p-1">
                {(["own", "rental"] as const).map((v) => (
                  <button
                    key={v}
                    type="button"
                    onClick={() => addressForm.setValue("ownership", v)}
                    className={`rounded-full px-3 py-1.5 text-sm font-medium transition-colors ${
                      addressForm.watch("ownership") === v ? "bg-ink text-white" : "text-text-muted"
                    }`}
                  >
                    {t(`customers.form.${v}`)}
                  </button>
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
