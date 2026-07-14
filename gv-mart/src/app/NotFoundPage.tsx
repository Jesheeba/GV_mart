import { Link } from "react-router-dom"
import { useTranslation } from "react-i18next"
import { Button } from "@/components/ui/button"

export function NotFoundPage() {
  const { t } = useTranslation()
  return (
    <div className="flex min-h-screen flex-col items-center justify-center gap-3 bg-bg px-6 text-center">
      <p className="text-sm font-semibold text-accent">404</p>
      <h1 className="text-2xl font-bold text-text">{t("notFound.title", "Page not found")}</h1>
      <Button nativeButton={false} render={<Link to="/login" />}>
        {t("notFound.backToLogin", "Back to login")}
      </Button>
    </div>
  )
}
