import { Construction } from "lucide-react"
import { useTranslation } from "react-i18next"
import { Card } from "@/components/ui/card"

/** `labelKey` is an i18n key (e.g. "nav.customers") — translated internally
 * so call sites (including route configs built outside the component tree)
 * never need to resolve the string themselves. */
export function ComingSoonPage({ labelKey }: { labelKey: string }) {
  const { t } = useTranslation()

  return (
    <div className="flex min-h-[70vh] items-center justify-center pt-2">
      <Card className="max-w-md items-center gap-3 text-center">
        <span className="flex size-12 items-center justify-center rounded-full bg-surface-alt text-text-muted">
          <Construction className="size-6" />
        </span>
        <h1 className="px-1 text-xl font-bold text-text">{t("shell.comingSoonTitle", { module: t(labelKey) })}</h1>
        <p className="px-1 text-sm text-text-muted">{t("shell.comingSoonBody")}</p>
      </Card>
    </div>
  )
}
