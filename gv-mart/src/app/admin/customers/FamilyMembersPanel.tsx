import { useState } from "react"
import { useTranslation } from "react-i18next"
import { zodResolver } from "@hookform/resolvers/zod"
import { useForm } from "react-hook-form"
import { Loader2, Plus, Star, Trash2, UserMinus } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { Card } from "@/components/ui/card"
import { memberSchema, type MemberInput } from "@/lib/validation/customer"
import { useAddMember, useMoveMemberOut, useRemoveMember, useSetPrimaryMember } from "@/hooks/useCustomers"
import type { MemberRow } from "@/services/customers"
import { useNavigate } from "react-router-dom"

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

      <ul className="space-y-2 px-1">
        {members.map((member) => (
          <li key={member.id} className="flex items-center justify-between rounded-xl border border-border px-3.5 py-2.5">
            <div>
              <div className="flex items-center gap-1.5">
                <span className="font-medium text-text">{member.name}</span>
                {member.is_primary ? (
                  <span className="flex items-center gap-1 rounded-full bg-accent-soft px-2 py-0.5 text-xs font-medium text-accent">
                    <Star className="size-3 fill-current" />
                    {t("customers.detail.primary")}
                  </span>
                ) : null}
              </div>
              <div className="text-xs text-text-muted">{member.mobile}</div>
            </div>
            <div className="flex items-center gap-1">
              {!member.is_primary && (
                <Button
                  size="xs"
                  variant="ghost"
                  disabled={setPrimary.isPending}
                  onClick={() => setPrimary.mutate(member.id)}
                >
                  {t("customers.detail.setPrimary")}
                </Button>
              )}
              {!member.is_primary && confirmingMoveOut !== member.id && (
                <Button size="icon-xs" variant="ghost" title={t("customers.detail.moveOut")} onClick={() => setConfirmingMoveOut(member.id)}>
                  <UserMinus className="size-3.5" />
                </Button>
              )}
              {confirmingMoveOut === member.id && (
                <span className="flex items-center gap-1 text-xs">
                  <button
                    type="button"
                    className="text-danger hover:underline"
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
                <Button size="icon-xs" variant="ghost" title={t("customers.detail.remove")} onClick={() => setConfirmingRemove(member.id)}>
                  <Trash2 className="size-3.5 text-danger" />
                </Button>
              )}
              {confirmingRemove === member.id && (
                <span className="flex items-center gap-1 text-xs">
                  <button
                    type="button"
                    className="text-danger hover:underline"
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
              {member.is_primary ? <span className="text-xs text-text-muted">{t("customers.detail.primaryLocked")}</span> : null}
            </div>
          </li>
        ))}
      </ul>

      {showAddForm ? (
        <form onSubmit={onAddMember} className="space-y-2 border-t border-border px-1 pt-3">
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
