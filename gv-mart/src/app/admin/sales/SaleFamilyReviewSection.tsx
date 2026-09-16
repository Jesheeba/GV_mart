import { useState } from "react"
import { useTranslation } from "react-i18next"
import { zodResolver } from "@hookform/resolvers/zod"
import { useForm } from "react-hook-form"
import { Loader2, Plus, Star } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Card } from "@/components/ui/card"
import { Input } from "@/components/ui/input"
import { memberSchema, FAMILY_RELATIONS, type MemberInput } from "@/lib/validation/customer"
import { useAddMember, useCustomer, useLogMemberGoogleReview } from "@/hooks/useCustomers"
import { avatarPalette, initials } from "@/lib/avatar"

/**
 * Read-only-ish sibling of FamilyMembersPanel, embedded in New Sale step 0.
 * Deliberately excludes edit/remove/move-out/set-primary — those stay
 * Customer Detail's job — and never calls useNavigate, so it can't redirect
 * the cashier out of the sale mid-flow. Both mutations it uses invalidate
 * ["customers","detail",customerId], the same key FamilyMembersPanel reads,
 * so a review logged or a member added here shows up there for free.
 */
export function SaleFamilyReviewSection({ orgId, customerId }: { orgId: string | undefined; customerId: string }) {
  const { t } = useTranslation()
  const { data: customer, isLoading } = useCustomer(customerId)
  const logReview = useLogMemberGoogleReview(customerId)
  const addMember = useAddMember(orgId, customerId)
  const [loggingReviewId, setLoggingReviewId] = useState<string | null>(null)
  const [showAddForm, setShowAddForm] = useState(false)

  const {
    register,
    handleSubmit,
    reset,
    formState: { errors },
  } = useForm<MemberInput>({ resolver: zodResolver(memberSchema), mode: "onChange" })

  if (isLoading || !customer) return null

  const members = customer.customer_members
  const atCap = members.length >= 5

  const onAddMember = handleSubmit((values) => {
    addMember.mutate({ ...values, relation: values.relation || undefined, profession: values.profession || null }, {
      onSuccess: () => {
        reset()
        setShowAddForm(false)
      },
    })
  })

  return (
    <Card className="gap-3 px-5">
      <div className="flex items-center justify-between">
        <h2 className="text-sm font-semibold text-text">{t("customers.detail.membersTitle", { count: members.length })}</h2>
        <Button
          type="button"
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

      {members.length === 0 ? (
        <p className="text-xs text-text-muted">{t("customers.detail.noMembersYet")}</p>
      ) : (
        <div className="grid grid-cols-1 gap-2.5 sm:grid-cols-2">
          {members.map((member) => {
            const palette = avatarPalette(member.name)
            return (
              <div key={member.id} className="flex items-start gap-2.5 rounded-xl border border-border bg-surface p-3">
                <span
                  className="flex size-8.5 shrink-0 items-center justify-center rounded-[10px] text-[11px] font-bold"
                  style={{ background: palette.bg, color: palette.fg }}
                >
                  {initials(member.name)}
                </span>
                <div className="min-w-0 flex-1">
                  <div className="flex flex-wrap items-center gap-1.5">
                    <span className="truncate text-sm font-semibold text-text">{member.name}</span>
                    {member.is_primary ? (
                      <span className="shrink-0 rounded-full bg-accent-soft px-1.75 py-0.5 text-[10px] font-bold text-accent">
                        {t("customers.detail.primary")}
                      </span>
                    ) : null}
                  </div>

                  {loggingReviewId === member.id ? (
                    <div className="mt-1 flex items-center gap-1">
                      {Array.from({ length: 5 }, (_, i) => (
                        <button
                          key={i}
                          type="button"
                          disabled={logReview.isPending}
                          aria-label={t("customers.detail.rateStars", { count: i + 1 })}
                          onClick={() => logReview.mutate({ memberId: member.id, stars: i + 1 }, { onSuccess: () => setLoggingReviewId(null) })}
                        >
                          <Star className="size-4 text-border hover:fill-warning hover:text-warning" />
                        </button>
                      ))}
                      <button type="button" className="ml-1 text-[11px] font-semibold text-text-muted hover:text-text" onClick={() => setLoggingReviewId(null)}>
                        {t("common.cancel")}
                      </button>
                    </div>
                  ) : member.google_review_stars ? (
                    <button type="button" className="mt-1 flex items-center gap-0.5" onClick={() => setLoggingReviewId(member.id)}>
                      {Array.from({ length: 5 }, (_, i) => (
                        <Star key={i} className={`size-3.5 ${i < member.google_review_stars! ? "fill-warning text-warning" : "text-border"}`} />
                      ))}
                      <span className="ml-1 text-[11px] font-semibold text-text-muted">{t("customers.detail.googleReview")}</span>
                    </button>
                  ) : (
                    <button
                      type="button"
                      className="mt-1 w-fit text-[11px] font-semibold text-text-muted hover:text-text"
                      onClick={() => setLoggingReviewId(member.id)}
                    >
                      {t("customers.detail.logGoogleReview")}
                    </button>
                  )}
                </div>
              </div>
            )
          })}
        </div>
      )}

      {showAddForm ? (
        <form onSubmit={onAddMember} className="space-y-2 border-t border-border pt-3">
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
          <Input placeholder={t("customers.form.memberProfession")} {...register("profession")} />
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
