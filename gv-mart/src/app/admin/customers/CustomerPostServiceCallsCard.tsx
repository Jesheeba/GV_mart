import { useTranslation } from "react-i18next"
import { Phone } from "lucide-react"
import { Card } from "@/components/ui/card"
import { Skeleton } from "@/components/ui/skeleton"
import { PostServiceAnswersList } from "@/components/shared/PostServiceAnswersList"
import { useProfile } from "@/hooks/useProfile"
import { useCustomerPostServiceCalls } from "@/hooks/useFollowupQuestions"
import { formatIstDateTime } from "@/lib/lead-followups"
import type { UserRole } from "@/lib/roles"

/** Every post-service call for this customer, newest first: outcome, note, answers, date. Master, sales_admin and operation_admin (same as the ticket card). */
export function CustomerPostServiceCallsCard({ customerId }: { customerId: string }) {
  const { t, i18n } = useTranslation()
  const { data: profile } = useProfile()
  const role = profile?.role as UserRole | undefined
  const calls = useCustomerPostServiceCalls(customerId, role)
  const allowed = role === "master" || role === "sales_admin" || role === "operation_admin"
  if (!allowed) return null
  const ta = i18n.language.startsWith("ta")

  return (
    <Card size="default" data-testid="customer-post-service-calls">
      <h3 className="mb-2 flex items-center gap-1.5 text-sm font-semibold text-text">
        <Phone className="size-3.5" />
        {t("customers.detail.postServiceCalls.title")}
      </h3>
      {calls.isLoading ? (
        <Skeleton className="h-16 w-full" />
      ) : calls.isError ? (
        <p className="text-sm text-danger">{t("common.error")}</p>
      ) : (calls.data ?? []).length === 0 ? (
        <p className="text-sm text-text-muted">{t("customers.detail.postServiceCalls.empty")}</p>
      ) : (
        <ul className="space-y-2">
          {(calls.data ?? []).map((c) => (
            <li key={c.id} className="rounded-xl bg-surface-alt px-3 py-2 text-xs">
              <p>
                <span className="font-semibold text-text">
                  {ta && c.post_service_outcomes?.label_ta ? c.post_service_outcomes.label_ta : (c.post_service_outcomes?.label_en ?? c.outcome_code)}
                </span>
                <span className="text-text-muted">
                  {" · "}
                  {formatIstDateTime(c.called_at, i18n.language)}
                  {c.profiles?.full_name ? ` · ${c.profiles.full_name}` : ""}
                </span>
              </p>
              {c.service_tickets?.name_of_complaint ? <p className="text-text-muted">{c.service_tickets.name_of_complaint}</p> : null}
              {c.followup_needed != null ? (
                <p className="text-text-muted">
                  {t("customers.detail.postServiceCalls.followupNeeded")}: {c.followup_needed ? t("common.yes") : t("common.no")}
                </p>
              ) : null}
              {c.note ? <p className="mt-0.5 whitespace-pre-wrap text-text">{c.note}</p> : null}
              <PostServiceAnswersList answers={c.post_service_call_answers ?? []} />
            </li>
          ))}
        </ul>
      )}
    </Card>
  )
}
