import { useEffect, useRef, useState } from "react"
import { useTranslation } from "react-i18next"
import { useNavigate } from "react-router-dom"
import { zodResolver } from "@hookform/resolvers/zod"
import { useForm } from "react-hook-form"
import { Loader2, Plus, Star, Trash2, UserMinus } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { memberSchema, FAMILY_RELATIONS, type MemberInput } from "@/lib/validation/customer"
import { useAddMember, useMoveMemberOut, useRemoveMember, useSetPrimaryMember } from "@/hooks/useCustomers"
import { avatarPalette, initials } from "@/lib/avatar"
import type { MemberRow } from "@/services/customers"

/**
 * Renders bare (no outer Card) so it drops cleanly into a tab panel that
 * already sits inside one (CustomerDetailPage's Family tab) or a card
 * already provided by the caller (CustomerFormPage's edit step) without
 * doubling up the border/shadow.
 */
export function FamilyMembersPanel({
  orgId,
  customerId,
  members,
}: {
  orgId: string | undefined
  customerId: string
  members: MemberRow[]
}) {
  const { t } = useTranslation()
  const navigate = useNavigate()
  const [showAddForm, setShowAddForm] = useState(false)
  const [confirmingRemove, setConfirmingRemove] = useState<string | null>(null)
  const [confirmingMoveOut, setConfirmingMoveOut] = useState<string | null>(null)
  const removeConfirmRef = useRef<HTMLButtonElement>(null)
  const moveOutConfirmRef = useRef<HTMLButtonElement>(null)

  useEffect(() => {
    if (confirmingRemove) removeConfirmRef.current?.focus()
  }, [confirmingRemove])

  useEffect(() => {
    if (confirmingMoveOut) moveOutConfirmRef.current?.focus()
  }, [confirmingMoveOut])

  const addMember = useAddMember(orgId, customerId)
  const removeMember = useRemoveMember(customerId)
  const setPrimary = useSetPrimaryMember(customerId)
  const moveOut = useMoveMemberOut(orgId, customerId)

  const {
    register,
    handleSubmit,
    reset,
    formState: { errors },
  } = useForm<MemberInput>({ resolver: zodResolver(memberSchema), mode: "onChange" })

  const atCap = members.length >= 5

  const onAddMember = handleSubmit((values) => {
    addMember.mutate({ ...values, relation: values.relation || undefined }, {
      onSuccess: () => {
        reset()
        setShowAddForm(false)
      },
    })
  })

  return (
    <div className="space-y-3.5">
      <div className="flex items-center justify-between px-1">
        <h2 className="text-lg font-semibold text-text">{t("customers.detail.membersTitle", { count: members.length })}</h2>
        <Button
          size="sm"
          variant="outline"
          disabled={atCap}
          title={atCap ? t("customers.form.maxMembersReached") : undefined}
          onClick={() => setShowAddForm((v) => !v)}
        >
          <Plus className="size-3.5" />
          {t("customers.detail.addMember")}
        </Button>
      </div>

      {atCap ? <p className="px-1 text-xs text-text-muted">{t("customers.form.maxMembersReached")}</p> : null}

      <div className="grid grid-cols-1 gap-3.5 px-1 sm:grid-cols-2">
        {members.map((member) => {
          const palette = avatarPalette(member.name)
          return (
            <div key={member.id} className="flex items-start gap-3.25 rounded-[18px] border border-border bg-surface p-4">
              <span
                className="flex size-10.5 shrink-0 items-center justify-center rounded-[12px] text-[13px] font-bold"
                style={{ background: palette.bg, color: palette.fg }}
              >
                {initials(member.name)}
              </span>
              <div className="min-w-0 flex-1">
                <div className="flex flex-wrap items-center gap-1.5">
                  <span className="truncate text-sm font-bold text-text">{member.name}</span>
                  {member.is_primary ? (
                    <span className="flex shrink-0 items-center gap-1 rounded-full bg-accent-soft px-2 py-0.5 text-[10px] font-bold text-accent">
                      <Star className="size-2.5 fill-current" />
                      {t("customers.detail.primary")}
                    </span>
                  ) : member.relation ? (
                    <span className="shrink-0 rounded-full bg-surface-alt px-2 py-0.5 text-[10px] font-bold text-text-muted">
                      {t(`customers.form.relation.${member.relation}`)}
                    </span>
                  ) : null}
                </div>
                <div className="gv-tnum text-xs text-text-muted">{member.mobile}</div>

                <div className="mt-1.5 flex flex-wrap items-center gap-x-2.5 gap-y-1 text-xs">
                  {!member.is_primary && (
                    <button
                      type="button"
                      className="font-semibold text-text-muted hover:text-text disabled:opacity-50"
                      disabled={setPrimary.isPending}
                      onClick={() => setPrimary.mutate(member.id)}
                    >
                      {t("customers.detail.setPrimary")}
                    </button>
                  )}
                  {!member.is_primary && confirmingMoveOut !== member.id && (
                    <button
                      type="button"
                      className="flex items-center gap-1 font-semibold text-text-muted hover:text-text"
                      title={t("customers.detail.moveOut")}
                      onClick={() => setConfirmingMoveOut(member.id)}
                    >
                      <UserMinus className="size-3" />
                    </button>
                  )}
                  {confirmingMoveOut === member.id && (
                    <span className="flex items-center gap-1.5">
                      <span className="text-text-muted">{t("customers.detail.confirmMoveOut")}</span>
                      <button
                        ref={moveOutConfirmRef}
                        type="button"
                        className="font-semibold text-danger hover:underline"
                        disabled={moveOut.isPending}
                        onClick={() =>
                          moveOut.mutate(member, {
                            onSuccess: (newCustomer) => {
                              setConfirmingMoveOut(null)
                              navigate(`/admin/customers/${newCustomer.id}`)
                            },
                          })
                        }
                      >
                        {moveOut.isPending ? <Loader2 className="size-3 animate-spin" /> : t("customers.detail.confirm")}
                      </button>
                      <button type="button" className="text-text-muted hover:underline" onClick={() => setConfirmingMoveOut(null)}>
                        {t("common.cancel")}
                      </button>
                    </span>
                  )}
                  {!member.is_primary && confirmingRemove !== member.id && (
                    <button
                      type="button"
                      className="flex items-center gap-1 font-semibold text-danger hover:underline"
                      title={t("customers.detail.remove")}
                      onClick={() => setConfirmingRemove(member.id)}
                    >
                      <Trash2 className="size-3" />
                    </button>
                  )}
                  {confirmingRemove === member.id && (
                    <span className="flex items-center gap-1.5">
                      <span className="text-text-muted">{t("customers.detail.confirmRemove")}</span>
                      <button
                        ref={removeConfirmRef}
                        type="button"
                        className="font-semibold text-danger hover:underline"
                        disabled={removeMember.isPending}
                        onClick={() => removeMember.mutate(member.id, { onSuccess: () => setConfirmingRemove(null) })}
                      >
                        {removeMember.isPending ? <Loader2 className="size-3 animate-spin" /> : t("customers.detail.confirm")}
                      </button>
                      <button type="button" className="text-text-muted hover:underline" onClick={() => setConfirmingRemove(null)}>
                        {t("common.cancel")}
                      </button>
                    </span>
                  )}
                  {member.is_primary ? <span className="text-text-muted">{t("customers.detail.primaryLocked")}</span> : null}
                </div>
              </div>
            </div>
          )
        })}
      </div>

      {showAddForm ? (
        <form onSubmit={onAddMember} className="space-y-2 border-t border-border px-1 pt-3.5">
          <div className="flex gap-2">
            <div className="flex-1 space-y-1">
              <Input placeholder={t("customers.form.memberName")} aria-invalid={!!errors.name} {...register("name")} />
              {errors.name ? <p className="text-xs text-danger">{t(errors.name.message!)}</p> : null}
            </div>
            <div className="flex-1 space-y-1">
              <Input placeholder={t("customers.form.memberMobile")} aria-invalid={!!errors.mobile} {...register("mobile")} />
              {errors.mobile ? <p className="text-xs text-danger">{t(errors.mobile.message!)}</p> : null}
            </div>
          </div>
          <select
            aria-label={t("customers.form.memberRelation")}
            defaultValue=""
            className="h-9 rounded-xl border border-border bg-surface px-3 text-sm text-text outline-none"
            {...register("relation")}
          >
            <option value="">{t("customers.form.memberRelationPlaceholder")}</option>
            {FAMILY_RELATIONS.map((r) => (
              <option key={r} value={r}>
                {t(`customers.form.relation.${r}`)}
              </option>
            ))}
          </select>
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
    </div>
  )
}
