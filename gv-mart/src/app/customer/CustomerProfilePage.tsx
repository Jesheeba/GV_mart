import { useState } from "react"
import { useTranslation } from "react-i18next"
import { zodResolver } from "@hookform/resolvers/zod"
import { useForm } from "react-hook-form"
import { Coins, Home as HomeIcon, Loader2, LogOut, Pencil, Plus, Star, Trash2, UserPlus } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { Card } from "@/components/ui/card"
import { FullPageError, FullPageLoader } from "@/components/shared/FullPageLoader"
import { useToast } from "@/components/ui/toast-context"
import { useProfile } from "@/hooks/useProfile"
import { signOut } from "@/services/auth"
import {
  useAddMyAddress,
  useAddMyMember,
  useDeleteMyAddress,
  useMyCustomerId,
  useMyCustomerRecord,
  useMyReferralPoints,
  useRemoveMyMember,
  useSetMyPrimaryAddress,
  useUpdateMyAddress,
  useUpdateMyProfession,
} from "@/hooks/useCustomerApp"
import { customerAddressSchema, customerMemberSchema, type CustomerAddressInput, type CustomerMemberInput } from "@/lib/validation/customerApp"
import type { AddressRow } from "@/services/customerApp"

const MAX_MEMBERS = 5

function AddressForm({
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
    },
  })

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
        <Button type="submit" size="sm" disabled={isPending}>
          {isPending ? <Loader2 className="size-3.5 animate-spin" /> : t("common.save")}
        </Button>
      </div>
    </form>
  )
}

function AddressesSection({ customerId, orgId }: { customerId: string; orgId: string | undefined }) {
  const { t } = useTranslation()
  const { toast } = useToast()
  const [adding, setAdding] = useState(false)
  const [editingId, setEditingId] = useState<string | null>(null)
  const [confirmingDelete, setConfirmingDelete] = useState<string | null>(null)

  const { data: record } = useMyCustomerRecord(customerId)
  const addresses = (record?.addresses ?? []) as AddressRow[]

  const addAddress = useAddMyAddress(orgId, customerId)
  const updateAddress = useUpdateMyAddress(customerId)
  const setPrimary = useSetMyPrimaryAddress(customerId)
  const deleteAddress = useDeleteMyAddress(customerId)

  return (
    <Card className="gap-3">
      <div className="flex items-center justify-between px-1">
        <h2 className="flex items-center gap-1.5 text-sm font-semibold text-text">
          <HomeIcon className="size-4 text-text-muted" />
          {t("customerApp.profile.addressesTitle")}
        </h2>
        {!adding ? (
          <Button size="sm" variant="outline" onClick={() => setAdding(true)}>
            <Plus className="size-3.5" />
            {t("customerApp.profile.addAddress")}
          </Button>
        ) : null}
      </div>

      {addresses.length === 0 && !adding ? <p className="px-1 text-sm text-text-muted">{t("customerApp.profile.noAddresses")}</p> : null}

      <ul className="space-y-2 px-1">
        {addresses.map((a) =>
          editingId === a.id ? (
            <li key={a.id}>
              <AddressForm
                initial={a}
                isPending={updateAddress.isPending}
                error={updateAddress.isError ? (updateAddress.error as Error).message : undefined}
                onCancel={() => setEditingId(null)}
                onSubmit={(values) => updateAddress.mutate({ addressId: a.id, input: values }, { onSuccess: () => setEditingId(null) })}
              />
            </li>
          ) : (
            <li key={a.id} className="flex items-start justify-between gap-2 rounded-xl border border-border px-3.5 py-2.5">
              <div className="min-w-0">
                <div className="flex items-center gap-1.5">
                  {a.is_primary ? (
                    <span className="flex items-center gap-1 rounded-full bg-accent-soft px-2 py-0.5 text-xs font-medium text-accent">
                      <Star className="size-3 fill-current" />
                      {t("customerApp.profile.primary")}
                    </span>
                  ) : null}
                  <span className="text-xs text-text-muted">{t(`customerApp.profile.address.${a.address_type}`)}</span>
                </div>
                <p className="truncate text-sm text-text">{[a.door_no, a.flat_no, a.street_cross, a.area, a.pincode].filter(Boolean).join(", ")}</p>
              </div>
              <div className="flex shrink-0 items-center gap-1">
                {!a.is_primary ? (
                  <Button
                    size="xs"
                    variant="ghost"
                    disabled={setPrimary.isPending}
                    onClick={() => setPrimary.mutate(a.id, { onError: () => toast.error(t("common.actionFailed")) })}
                  >
                    {t("customerApp.profile.setPrimary")}
                  </Button>
                ) : null}
                <Button size="icon-xs" variant="ghost" title={t("customerApp.profile.edit")} onClick={() => setEditingId(a.id)}>
                  <Pencil className="size-3.5" />
                </Button>
                {!a.is_primary && confirmingDelete !== a.id ? (
                  <Button size="icon-xs" variant="ghost" title={t("common.remove")} onClick={() => setConfirmingDelete(a.id)}>
                    <Trash2 className="size-3.5 text-danger" />
                  </Button>
                ) : null}
                {confirmingDelete === a.id ? (
                  <span className="flex items-center gap-1 text-xs">
                    <button
                      type="button"
                      className="text-danger hover:underline"
                      disabled={deleteAddress.isPending}
                      onClick={() =>
                        deleteAddress.mutate(a.id, {
                          onSuccess: () => setConfirmingDelete(null),
                          onError: () => toast.error(t("common.actionFailed")),
                        })
                      }
                    >
                      {deleteAddress.isPending ? <Loader2 className="size-3 animate-spin" /> : t("customerApp.profile.confirm")}
                    </button>
                    <button type="button" className="text-text-muted hover:underline" onClick={() => setConfirmingDelete(null)}>
                      {t("common.cancel")}
                    </button>
                  </span>
                ) : null}
              </div>
            </li>
          )
        )}
      </ul>

      {adding ? (
        <AddressForm
          isPending={addAddress.isPending}
          error={addAddress.isError ? (addAddress.error as Error).message : undefined}
          onCancel={() => setAdding(false)}
          onSubmit={(values) =>
            addAddress.mutate({ input: values, makePrimary: addresses.length === 0 }, { onSuccess: () => setAdding(false) })
          }
        />
      ) : null}
    </Card>
  )
}

function MembersSection({ customerId, orgId }: { customerId: string; orgId: string | undefined }) {
  const { t } = useTranslation()
  const { toast } = useToast()
  const [showAddForm, setShowAddForm] = useState(false)
  const [confirmingRemove, setConfirmingRemove] = useState<string | null>(null)

  const { data: record } = useMyCustomerRecord(customerId)
  const members = record?.customer_members ?? []

  const addMember = useAddMyMember(orgId, customerId)
  const removeMember = useRemoveMyMember(customerId)

  const {
    register,
    handleSubmit,
    reset,
    formState: { errors },
  } = useForm<CustomerMemberInput>({ resolver: zodResolver(customerMemberSchema), mode: "onChange" })

  const atCap = members.length >= MAX_MEMBERS

  const onAdd = handleSubmit((values) => {
    if (atCap) return
    addMember.mutate(values, {
      onSuccess: () => {
        reset()
        setShowAddForm(false)
      },
    })
  })

  return (
    <Card className="gap-3">
      <div className="flex items-center justify-between px-1">
        <h2 className="flex items-center gap-1.5 text-sm font-semibold text-text">
          <UserPlus className="size-4 text-text-muted" />
          {t("customerApp.profile.membersTitle", { count: members.length, max: MAX_MEMBERS })}
        </h2>
        <Button
          size="sm"
          variant="outline"
          disabled={atCap}
          title={atCap ? t("customerApp.profile.maxMembersReached") : undefined}
          onClick={() => setShowAddForm((v) => !v)}
        >
          <Plus className="size-3.5" />
          {t("customerApp.profile.addMember")}
        </Button>
      </div>

      {atCap ? <p className="px-1 text-xs text-text-muted">{t("customerApp.profile.maxMembersReached")}</p> : null}
      {members.length === 0 ? <p className="px-1 text-sm text-text-muted">{t("customerApp.profile.noMembers")}</p> : null}

      <ul className="space-y-2 px-1">
        {members.map((m) => (
          <li key={m.id} className="flex items-center justify-between rounded-xl border border-border px-3.5 py-2.5">
            <div>
              <div className="flex items-center gap-1.5">
                <span className="font-medium text-text">{m.name}</span>
                {m.is_primary ? (
                  <span className="flex items-center gap-1 rounded-full bg-accent-soft px-2 py-0.5 text-xs font-medium text-accent">
                    <Star className="size-3 fill-current" />
                    {t("customerApp.profile.primary")}
                  </span>
                ) : null}
              </div>
              <div className="text-xs text-text-muted">{m.mobile}</div>
            </div>
            {!m.is_primary ? (
              confirmingRemove === m.id ? (
                <span className="flex items-center gap-1 text-xs">
                  <button
                    type="button"
                    className="text-danger hover:underline"
                    disabled={removeMember.isPending}
                    onClick={() =>
                      removeMember.mutate(m.id, {
                        onSuccess: () => setConfirmingRemove(null),
                        onError: () => toast.error(t("common.actionFailed")),
                      })
                    }
                  >
                    {removeMember.isPending ? <Loader2 className="size-3 animate-spin" /> : t("customerApp.profile.confirm")}
                  </button>
                  <button type="button" className="text-text-muted hover:underline" onClick={() => setConfirmingRemove(null)}>
                    {t("common.cancel")}
                  </button>
                </span>
              ) : (
                <Button size="icon-xs" variant="ghost" title={t("common.remove")} onClick={() => setConfirmingRemove(m.id)}>
                  <Trash2 className="size-3.5 text-danger" />
                </Button>
              )
            ) : null}
          </li>
        ))}
      </ul>

      {showAddForm ? (
        <form onSubmit={onAdd} className="space-y-2 border-t border-border px-1 pt-3">
          <div className="flex gap-2">
            <div className="flex-1 space-y-1">
              <Input placeholder={t("customerApp.profile.memberName")} aria-invalid={!!errors.name} {...register("name")} />
              {errors.name ? <p className="text-xs text-danger">{t(errors.name.message!)}</p> : null}
            </div>
            <div className="flex-1 space-y-1">
              <Input placeholder={t("customerApp.profile.memberMobile")} aria-invalid={!!errors.mobile} {...register("mobile")} />
              {errors.mobile ? <p className="text-xs text-danger">{t(errors.mobile.message!)}</p> : null}
            </div>
          </div>
          {addMember.isError ? <p className="text-xs text-danger">{(addMember.error as Error).message}</p> : null}
          <div className="flex justify-end gap-2">
            <Button type="button" size="sm" variant="ghost" onClick={() => setShowAddForm(false)}>
              {t("common.cancel")}
            </Button>
            <Button type="submit" size="sm" disabled={addMember.isPending}>
              {addMember.isPending ? <Loader2 className="size-3.5 animate-spin" /> : t("common.save")}
            </Button>
          </div>
        </form>
      ) : null}
    </Card>
  )
}

function ProfessionField({ customerId, profession }: { customerId: string; profession: string | null }) {
  const { t } = useTranslation()
  const { toast } = useToast()
  const [editing, setEditing] = useState(false)
  const [value, setValue] = useState(profession ?? "")
  const updateProfession = useUpdateMyProfession(customerId)

  if (!editing) {
    return (
      <button
        type="button"
        onClick={() => {
          setValue(profession ?? "")
          setEditing(true)
        }}
        className="flex w-full items-center justify-between rounded-xl border border-border px-3.5 py-2.5 text-left"
      >
        <span>
          <span className="block text-xs text-text-muted">{t("customerApp.profile.profession")}</span>
          <span className="text-sm text-text">{profession || t("customerApp.profile.notSet")}</span>
        </span>
        <span className="text-xs font-medium text-accent">{t("customerApp.profile.edit")}</span>
      </button>
    )
  }

  return (
    <div className="flex items-center gap-2">
      <Input value={value} onChange={(e) => setValue(e.target.value)} placeholder={t("customerApp.profile.profession")} className="flex-1" />
      <Button
        size="sm"
        disabled={updateProfession.isPending}
        onClick={() =>
          updateProfession.mutate(value, {
            onSuccess: () => setEditing(false),
            onError: () => toast.error(t("common.actionFailed")),
          })
        }
      >
        {updateProfession.isPending ? <Loader2 className="size-3.5 animate-spin" /> : t("common.save")}
      </Button>
      <Button size="sm" variant="ghost" onClick={() => setEditing(false)}>
        {t("common.cancel")}
      </Button>
    </div>
  )
}

function ReferralWalletCard({ customerId }: { customerId: string }) {
  const { t } = useTranslation()
  const { data: points, isLoading } = useMyReferralPoints(customerId)

  const total = (points ?? []).reduce((sum, p) => sum + p.points, 0)

  return (
    <Card className="gap-2">
      <div className="flex items-center gap-2 px-1">
        <span className="flex size-8 items-center justify-center rounded-full bg-accent-soft text-accent">
          <Coins className="size-4" />
        </span>
        <div>
          <p className="text-xs text-text-muted">{t("customerApp.profile.referralWallet")}</p>
          {isLoading ? (
            <p className="text-sm text-text-muted">{t("common.loading")}</p>
          ) : (
            <p className="text-lg font-bold text-text">{t("customerApp.profile.referralPoints", { count: total })}</p>
          )}
        </div>
      </div>
      {!isLoading && (points ?? []).length === 0 ? <p className="px-1 text-xs text-text-muted">{t("customerApp.profile.noReferralActivity")}</p> : null}
    </Card>
  )
}

export function CustomerProfilePage() {
  const { t } = useTranslation()
  const { data: profile, isLoading: loadingProfile, isError, refetch } = useProfile()
  const { customerId, orgId, isLoading: loadingCustomerId } = useMyCustomerId()
  const { data: record, isLoading: loadingRecord, isError: recordError, refetch: refetchRecord } = useMyCustomerRecord(customerId)

  if (loadingProfile || loadingCustomerId || (customerId && loadingRecord)) return <FullPageLoader label={t("common.loading")} />
  if (isError || !profile) {
    return <FullPageError message={t("auth.profileLoadError")} onRetry={() => refetch()} retryLabel={t("common.retry")} />
  }
  if (recordError) {
    return <FullPageError message={t("customerApp.profile.loadError")} onRetry={() => refetchRecord()} retryLabel={t("common.retry")} />
  }

  return (
    <div className="space-y-4 pb-4 pt-2">
      <div className="flex items-center justify-between">
        <h1 className="text-xl font-bold text-text">{t("customerApp.profile.title")}</h1>
        <Button size="sm" variant="outline" onClick={() => signOut()}>
          <LogOut className="size-3.5" />
          {t("shell.signOut")}
        </Button>
      </div>

      <Card className="gap-3">
        <div className="flex items-center gap-3 px-1">
          <span className="flex size-12 items-center justify-center rounded-full bg-ink text-base font-semibold text-white">
            {profile.full_name.slice(0, 2).toUpperCase()}
          </span>
          <div className="min-w-0">
            <p className="truncate text-base font-semibold text-text">{profile.full_name}</p>
            <p className="text-sm text-text-muted">{record?.mobile ?? profile.phone}</p>
          </div>
        </div>
        {customerId ? <ProfessionField customerId={customerId} profession={record?.profession ?? null} /> : null}
      </Card>

      {customerId ? <ReferralWalletCard customerId={customerId} /> : null}

      {customerId ? <AddressesSection customerId={customerId} orgId={orgId} /> : null}

      {customerId ? <MembersSection customerId={customerId} orgId={orgId} /> : null}
    </div>
  )
}
