import { describe, expect, it } from "vitest"
import {
  buildAnswersPayload,
  choiceValueFromLabel,
  choicesToLines,
  formatStoredAnswer,
  missingRequired,
  outcomeSkipsRequiredAnswers,
  parseChoiceLines,
  pickText,
  type FollowupQuestion,
} from "./followup-questions"

const q = (id: string, answer_type: FollowupQuestion["answer_type"], is_required = false, extra: Partial<FollowupQuestion> = {}): FollowupQuestion => ({
  id,
  text_en: id,
  text_ta: "",
  answer_type,
  choices: null,
  is_required,
  sort_order: 1,
  ...extra,
})

describe("followup questions helpers", () => {
  it("reports required questions that are blank; whitespace is blank, false is an answer", () => {
    const qs = [q("a", "yes_no", true), q("b", "text", true), q("c", "rating", true), q("d", "text", false)]
    expect(missingRequired(qs, { a: false, b: "   ", c: null }).map((x) => x.id)).toEqual(["b", "c"])
    expect(missingRequired(qs, { a: true, b: "ok", c: 3 })).toEqual([])
  })

  it("builds the payload without blank answers and trims text", () => {
    const qs = [q("a", "yes_no"), q("b", "text"), q("c", "rating"), q("d", "choice")]
    expect(buildAnswersPayload(qs, { a: false, b: "  hi  ", c: null, d: "" })).toEqual([
      { question_id: "a", value: false },
      { question_id: "b", value: "hi" },
    ])
  })

  it("skips required answers for retry outcomes and no_answer_needed only", () => {
    expect(outcomeSkipsRequiredAnswers({ retry: true, code: "not_reachable" })).toBe(true)
    expect(outcomeSkipsRequiredAnswers({ retry: true, code: "call_later" })).toBe(true)
    expect(outcomeSkipsRequiredAnswers({ retry: false, code: "no_answer_needed" })).toBe(true)
    expect(outcomeSkipsRequiredAnswers({ retry: false, code: "satisfied" })).toBe(false)
    expect(outcomeSkipsRequiredAnswers(null)).toBe(false)
  })

  it("uses Tamil text only when the language is Tamil and the Tamil text is filled in", () => {
    expect(pickText("Is it working?", "", "ta")).toBe("Is it working?")
    expect(pickText("Is it working?", "TA", "ta")).toBe("TA")
    expect(pickText("Is it working?", "TA", "en")).toBe("Is it working?")
  })

  it("formats saved answers from the stored snapshot", () => {
    const base = { question_text_en: "x", question_text_ta: "", question_choices: null, answer_bool: null, answer_int: null, answer_text: null }
    expect(formatStoredAnswer({ ...base, answer_type: "yes_no", answer_bool: true }, "en", "Yes", "No")).toBe("Yes")
    expect(formatStoredAnswer({ ...base, answer_type: "yes_no", answer_bool: false }, "en", "Yes", "No")).toBe("No")
    expect(formatStoredAnswer({ ...base, answer_type: "rating", answer_int: 4 }, "en", "Yes", "No")).toBe("4 / 5")
    expect(
      formatStoredAnswer({ ...base, answer_type: "choice", answer_text: "pm", question_choices: [{ value: "pm", label_en: "Afternoon" }] }, "en", "Yes", "No")
    ).toBe("Afternoon")
    expect(formatStoredAnswer({ ...base, answer_type: "choice", answer_text: "gone", question_choices: [] }, "en", "Yes", "No")).toBe("gone")
    expect(formatStoredAnswer({ ...base, answer_type: "text", answer_text: "Fine" }, "en", "Yes", "No")).toBe("Fine")
  })

  it("parses choice lines, rejects too few or duplicate choices, and round-trips", () => {
    const parsed = parseChoiceLines("Morning | AM\nAfternoon")
    expect(parsed).toEqual([
      { value: "morning", label_en: "Morning", label_ta: "AM" },
      { value: "afternoon", label_en: "Afternoon", label_ta: "" },
    ])
    expect(() => parseChoiceLines("Only one")).toThrow("choices.count")
    expect(() => parseChoiceLines("Same\nsame")).toThrow("choices.duplicate")
    expect(choicesToLines(parsed)).toBe("Morning | AM\nAfternoon")
    expect(choiceValueFromLabel("  Next Week!  ")).toBe("next_week")
  })
})
