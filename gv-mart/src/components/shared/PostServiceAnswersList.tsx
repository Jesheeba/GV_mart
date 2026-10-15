import { useTranslation } from "react-i18next"
import { formatStoredAnswer, pickText, type StoredAnswer } from "@/lib/followup-questions"

/** The answers given on one call, shown with the wording stored at the time (later edits to a question do not change it). */
export function PostServiceAnswersList({ answers }: { answers: (StoredAnswer & { id: string })[] }) {
  const { t, i18n } = useTranslation()
  if (answers.length === 0) return null
  const yes = t("common.yes")
  const no = t("common.no")
  return (
    <ul className="mt-1.5 space-y-1" data-testid="post-service-answers">
      {answers.map((a) => (
        <li key={a.id} className="flex flex-wrap justify-between gap-x-3 text-xs">
          <span className="text-text-muted">{pickText(a.question_text_en, a.question_text_ta, i18n.language)}</span>
          <span className="whitespace-pre-wrap font-semibold text-text">{formatStoredAnswer(a, i18n.language, yes, no)}</span>
        </li>
      ))}
    </ul>
  )
}
