import type { Json } from "@/types/database"

// Master-defined follow-up call questions (migration 20261027100000). Pure helpers shared by the call sheet, the
// ticket/customer history and the masters screen. The server is the authority: it re-validates every answer and enforces
// required questions; these helpers only keep the screen honest before the call is saved.

export type AnswerType = "yes_no" | "choice" | "rating" | "text"
export type ChoiceOption = { value: string; label_en: string; label_ta?: string }
export type AnswerValue = boolean | number | string | null
export type AnswerMap = Record<string, AnswerValue>

export type FollowupQuestion = {
  id: string
  text_en: string
  text_ta: string
  answer_type: AnswerType
  choices: Json | null
  is_required: boolean
  sort_order: number
}

export const RATING_VALUES = [1, 2, 3, 4, 5] as const
export const FOLLOWUP_TICKET_TYPES = ["paid", "warranty", "amc", "installation", "rental"] as const
export const MAX_TEXT_ANSWER = 2000

export function parseChoices(raw: Json | null | undefined): ChoiceOption[] {
  if (!Array.isArray(raw)) return []
  const out: ChoiceOption[] = []
  for (const c of raw) {
    if (c && typeof c === "object" && !Array.isArray(c)) {
      const o = c as Record<string, unknown>
      if (typeof o.value === "string" && typeof o.label_en === "string") {
        out.push({ value: o.value, label_en: o.label_en, label_ta: typeof o.label_ta === "string" ? o.label_ta : undefined })
      }
    }
  }
  return out
}

/** Tamil text when the UI is Tamil and the master has filled it in, otherwise English. */
export function pickText(en: string, ta: string | null | undefined, lang: string): string {
  return lang.startsWith("ta") && ta && ta.trim() ? ta : en
}

export function choiceLabel(c: ChoiceOption, lang: string): string {
  return pickText(c.label_en, c.label_ta, lang)
}

/** Retry outcomes (customer not reached / asked to call later) and "no answer needed" never require answers. Same rule as the server. */
export function outcomeSkipsRequiredAnswers(o: { retry: boolean; code: string } | null | undefined): boolean {
  return !!o && (o.retry || o.code === "no_answer_needed")
}

export function isBlank(v: AnswerValue | undefined): boolean {
  return v === null || v === undefined || (typeof v === "string" && v.trim() === "")
}

/** Required questions that still have no answer. */
export function missingRequired(questions: FollowupQuestion[], answers: AnswerMap): FollowupQuestion[] {
  return questions.filter((q) => q.is_required && isBlank(answers[q.id]))
}

/** The p_answers payload: blank answers are left out so a non-required question stays unanswered. */
export function buildAnswersPayload(questions: FollowupQuestion[], answers: AnswerMap): { question_id: string; value: boolean | number | string }[] {
  const out: { question_id: string; value: boolean | number | string }[] = []
  for (const q of questions) {
    const v = answers[q.id]
    if (isBlank(v)) continue
    if (q.answer_type === "text") out.push({ question_id: q.id, value: String(v).trim().slice(0, MAX_TEXT_ANSWER) })
    else out.push({ question_id: q.id, value: v as boolean | number | string })
  }
  return out
}

export type StoredAnswer = {
  question_text_en: string
  question_text_ta: string
  answer_type: AnswerType
  question_choices: Json | null
  answer_bool: boolean | null
  answer_int: number | null
  answer_text: string | null
}

/** Display value of a saved answer, using the wording snapshot stored with it (never the live question). */
export function formatStoredAnswer(a: StoredAnswer, lang: string, yes: string, no: string): string {
  switch (a.answer_type) {
    case "yes_no":
      return a.answer_bool ? yes : no
    case "rating":
      return a.answer_int == null ? "—" : `${a.answer_int} / 5`
    case "choice": {
      const c = parseChoices(a.question_choices).find((x) => x.value === a.answer_text)
      return c ? choiceLabel(c, lang) : (a.answer_text ?? "—")
    }
    default:
      return a.answer_text ?? "—"
  }
}

/** Choice values must be unique; a code is made from the English label. */
export function choiceValueFromLabel(label: string): string {
  return label
    .toLowerCase()
    .normalize("NFKD")
    .replace(/[^a-z0-9]+/g, "_")
    .replace(/^_+|_+$/g, "")
    .slice(0, 60)
}

/** "English | Tamil (optional)" lines -> choices. Throws an Error whose message is a short code. */
export function parseChoiceLines(text: string): ChoiceOption[] {
  const lines = text.split("\n").map((l) => l.trim()).filter(Boolean)
  if (lines.length < 2 || lines.length > 10) throw new Error("choices.count")
  const seen = new Set<string>()
  return lines.map((line) => {
    const [en, ta] = line.split("|").map((s) => s.trim())
    const value = choiceValueFromLabel(en ?? "")
    if (!en || !value) throw new Error("choices.label")
    if (seen.has(value)) throw new Error("choices.duplicate")
    seen.add(value)
    return { value, label_en: en, label_ta: ta || "" }
  })
}

export function choicesToLines(raw: Json | null | undefined): string {
  return parseChoices(raw)
    .map((c) => (c.label_ta ? `${c.label_en} | ${c.label_ta}` : c.label_en))
    .join("\n")
}
