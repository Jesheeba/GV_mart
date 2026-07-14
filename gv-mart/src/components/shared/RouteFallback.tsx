import { useTranslation } from "react-i18next"
import { FullPageLoader } from "@/components/shared/FullPageLoader"

/** Suspense fallback for the lazy-loaded route shells in src/router.tsx —
 * kept in its own file (rather than defined inline in router.tsx) so that
 * file's only export stays the non-component `router`, avoiding an
 * only-export-components Fast Refresh lint warning. */
export function RouteFallback() {
  const { t } = useTranslation()
  return <FullPageLoader label={t("common.loading")} />
}
