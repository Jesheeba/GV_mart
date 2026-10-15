import { useTranslation } from "react-i18next"
import { Phone } from "lucide-react"
import { Card } from "@/components/ui/card"
import { useProfile } from "@/hooks/useProfile"
import { useTicketPostServiceCalls } from "@/hooks/usePostServiceFollowups"
import { PostServiceAnswersList } from "@/components/shared/PostServiceAnswersList"
import { formatIstDateTime } from "@/lib/lead-followups"
import { canWorkFollowups } from "@/hooks/useLeadFollowups"
import type { UserRole } from "@/lib/roles"

/** Post-service call history on the ticket page. Shows nothing for tickets that never had a call. */
export function PostServiceCallsCard({ ticketId }: { ticketId: string }) {
  const { t, i18n } = useTranslation()
  const { data: profile } = useProfile()
  const role = profile?.role as UserRole | undefined
  const canSee = canWorkFollowups(role) || role === "operation_admin"
  const calls = useTicketPostServiceCalls(canSee ? ticketId : undefined)
  if (!canSee || !calls.data || calls.data.length === 0) return null
  const ta = i18n.language.startsWith("ta")

  return (
    <Card className="gap-2.5 px-5" data-testid="post-service-calls">
      <h3 className="flex items-center gap-1.5 text-sm font-semibold text-text">
        <Phone className="size-3.5" />
        {t("service.detail.postServiceCalls")}
      </h3>
      <ul className="space-y-2">
        {calls.data.map((c) => (
          <li key={c.id} className="rounded-xl bg-surface-alt px-3 py-2 text-xs">
            <p>
              <span className="font-semibold text-text">{ta && c.post_service_outcomes?.label_ta ? c.post_service_outcomes.label_ta : c.post_service_outcomes?.label_en ?? c.outcome_code}</span>
              <span className="text-text-muted">
                {" · "}
                {formatIstDateTime(c.called_at, i18n.language)}
                {c.profiles?.full_name ? ` · ${c.profiles.full_name}` : ""}
              </span>
            </p>
            {c.note ? <p className="mt-0.5 whitespace-pre-wrap text-text">{c.note}</p> : null}
            <PostServiceAnswersList answers={c.post_service_call_answers ?? []} />
          </li>
        ))}
      </ul>
    </Card>
  )
}
