import { supabase } from "@/lib/supabase"
import type { Database, Json, Tables, TablesInsert, TablesUpdate } from "@/types/database"
import type { FollowupQuestion, StoredAnswer } from "@/lib/followup-questions"

// Master-defined follow-up call questions (migration 20261027100000).
// Questions and ticket-type links are master-written tables (RLS); answers are written ONLY by log_post_service_call.

export type FollowupQuestionRow = Tables<"followup_questions">
export type FollowupQuestionTypeLink = Tables<"followup_question_ticket_types">
export type PostServiceAnswerRow = Tables<"post_service_call_answers">
export type AnswersReportRow = Database["public"]["Functions"]["report_followup_question_answers"]["Returns"][number]

export async function listFollowupQuestions(orgId: string): Promise<FollowupQuestionRow[]> {
  const { data, error } = await supabase.from("followup_questions").select("*").eq("org_id", orgId).order("sort_order").order("created_at")
  if (error) throw error
  return data
}
export async function createFollowupQuestion(row: TablesInsert<"followup_questions">): Promise<FollowupQuestionRow> {
  const { data, error } = await supabase.from("followup_questions").insert(row).select().single()
  if (error) throw error
  return data
}
export async function updateFollowupQuestion(id: string, patch: TablesUpdate<"followup_questions">): Promise<FollowupQuestionRow> {
  const { data, error } = await supabase.from("followup_questions").update({ ...patch, updated_at: new Date().toISOString() }).eq("id", id).select().single()
  if (error) throw error
  return data
}
/** Questions are never deleted (no DELETE grant, trigger refuses): the master deactivates them. */
export async function deleteFollowupQuestion(): Promise<void> {
  throw new Error("Questions are deactivated, not deleted")
}

export async function listFollowupQuestionTypeLinks(orgId: string): Promise<FollowupQuestionTypeLink[]> {
  const { data, error } = await supabase.from("followup_question_ticket_types").select("*").eq("org_id", orgId)
  if (error) throw error
  return data
}
export async function setFollowupQuestionTypeLink(input: { orgId: string; questionId: string; ticketType: FollowupQuestionTypeLink["ticket_type"]; on: boolean }): Promise<void> {
  if (input.on) {
    const { error } = await supabase
      .from("followup_question_ticket_types")
      .insert({ org_id: input.orgId, question_id: input.questionId, ticket_type: input.ticketType })
    if (error && error.code !== "23505") throw error
    return
  }
  const { error } = await supabase.from("followup_question_ticket_types").delete().eq("question_id", input.questionId).eq("ticket_type", input.ticketType)
  if (error) throw error
}

/** The active questions this call sheet should show (server applies scope and ticket-type rules). */
export async function getPostServiceQuestions(followupId: string): Promise<FollowupQuestion[]> {
  const { data, error } = await supabase.rpc("get_post_service_questions", { p_followup_id: followupId })
  if (error) throw error
  return (data ?? []) as FollowupQuestion[]
}

export type CustomerPostServiceCall = Tables<"post_service_calls"> & {
  profiles: { full_name: string } | null
  post_service_outcomes: { label_en: string; label_ta: string } | null
  service_tickets: { name_of_complaint: string | null; type: string } | null
  post_service_call_answers: (StoredAnswer & { id: string; question_id: string })[]
}

/** Every post-service call for one customer, newest first, with the answers given. Staff-readable (RLS). */
export async function listCustomerPostServiceCalls(customerId: string): Promise<CustomerPostServiceCall[]> {
  const { data, error } = await supabase
    .from("post_service_calls")
    .select(
      "*, profiles:called_by(full_name), post_service_outcomes(label_en, label_ta), service_tickets(name_of_complaint, type), post_service_call_answers(id, question_id, question_text_en, question_text_ta, answer_type, question_choices, answer_bool, answer_int, answer_text)"
    )
    .eq("customer_id", customerId)
    .order("called_at", { ascending: false })
  if (error) throw error
  return (data ?? []) as unknown as CustomerPostServiceCall[]
}

export async function getFollowupAnswersReport(from: string, to: string): Promise<AnswersReportRow[]> {
  const { data, error } = await supabase.rpc("report_followup_question_answers", { p_from: from, p_to: to })
  if (error) throw error
  return data ?? []
}

export type { Json }
