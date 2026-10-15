import { supabase } from "@/lib/supabase"
import type { Database, Tables } from "@/types/database"
import { scopeArgs, type FollowupScope } from "@/services/leadFollowups"
import type { StoredAnswer } from "@/lib/followup-questions"

// Post-service follow-up calls (batch-17 item 13, migration 20261014100000). Reads go through
// list_post_service_followups (master + sales_admin only); every write is the log_post_service_call RPC.

export type PostServiceFollowupItem = Database["public"]["Functions"]["list_post_service_followups"]["Returns"][number]
export type PostServiceOutcomeRow = Tables<"post_service_outcomes">

export async function listPostServiceFollowups(filters: { scope?: FollowupScope } = {}): Promise<PostServiceFollowupItem[]> {
  const { data, error } = await supabase.rpc("list_post_service_followups", { p_bucket: "all", ...scopeArgs(filters.scope) })
  if (error) throw error
  return data ?? []
}

export type LogPostServiceCallInput = {
  followupId: string
  outcomeId: string
  note?: string | null
  nextDueAt?: string | null
  /** Answers to the master-defined questions: [{ question_id, value }]. Omitted = none (behaves as before). */
  answers?: { question_id: string; value: boolean | number | string }[] | null
  /** "Follow-up needed?" - true keeps the same follow-up open at nextDueAt. Ignored by the server for retry outcomes. */
  followupNeeded?: boolean | null
}
export type LogPostServiceCallResult = {
  call_id: string
  followup_id: string
  ticket_id: string
  status: "open" | "done"
  next_due_at: string | null
  alerted: boolean
  answers_saved: number
  followup_needed: boolean | null
}

export async function logPostServiceCall(i: LogPostServiceCallInput): Promise<LogPostServiceCallResult> {
  const { data, error } = await supabase.rpc("log_post_service_call", {
    p_followup_id: i.followupId,
    p_outcome_id: i.outcomeId,
    p_note: i.note ?? null,
    p_next_due_at: i.nextDueAt ?? null,
    p_answers: i.answers && i.answers.length > 0 ? i.answers : null,
    p_followup_needed: i.followupNeeded ?? null,
  })
  if (error) throw error
  return data as unknown as LogPostServiceCallResult
}

export type TicketPostServiceCall = Tables<"post_service_calls"> & {
  profiles: { full_name: string } | null
  post_service_outcomes: { label_en: string; label_ta: string } | null
  post_service_call_answers: (StoredAnswer & { id: string; question_id: string })[]
}

/** Call history for one ticket (newest first). Staff-readable table; empty for tickets that never got a call. */
export async function listTicketPostServiceCalls(ticketId: string): Promise<TicketPostServiceCall[]> {
  const { data, error } = await supabase
    .from("post_service_calls")
    .select(
      "*, profiles:called_by(full_name), post_service_outcomes(label_en, label_ta), post_service_call_answers(id, question_id, question_text_en, question_text_ta, answer_type, question_choices, answer_bool, answer_int, answer_text)"
    )
    .eq("ticket_id", ticketId)
    .order("called_at", { ascending: false })
  if (error) throw error
  return (data ?? []) as unknown as TicketPostServiceCall[]
}

export const POST_SERVICE_TICKET_TYPES = ["paid", "warranty", "installation", "amc", "rental"] as const
