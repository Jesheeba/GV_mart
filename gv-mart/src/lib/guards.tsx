import { Navigate, Outlet, useLocation } from "react-router-dom"
import { useTranslation } from "react-i18next"
import { useAuth } from "@/hooks/useAuth"
import { useProfile } from "@/hooks/useProfile"
import { FullPageError, FullPageLoader } from "@/components/shared/FullPageLoader"
import { roleHomePath, type UserRole } from "@/lib/roles"
import { signOut } from "@/services/auth"

/** Redirects to /login when there's no session. RLS is the real boundary — this is UX. */
export function RequireAuth() {
  const { t } = useTranslation()
  const { session, loading } = useAuth()
  const location = useLocation()

  if (loading) return <FullPageLoader label={t("common.loading")} />
  if (!session) return <Navigate to="/login" replace state={{ from: location.pathname }} />

  return <Outlet />
}

/**
 * Redirects to the caller's own role home when their role isn't in `roles`.
 * A sales_admin hitting an operation_admin/master-only URL lands back on
 * /admin, never on the restricted page — RLS blocks the data regardless.
 */
export function RequireRole({ roles }: { roles: UserRole[] }) {
  const { t } = useTranslation()
  const { data: profile, isLoading, isError, refetch } = useProfile()

  if (isLoading) return <FullPageLoader label={t("common.loading")} />
  if (isError || !profile) {
    return (
      <FullPageError
        message={t("auth.profileLoadError")}
        onRetry={() => refetch()}
        retryLabel={t("common.retry")}
      />
    )
  }
  if (!roles.includes(profile.role)) {
    return <Navigate to={roleHomePath(profile.role)} replace />
  }

  return <Outlet />
}

export function useSignOut() {
  return async () => {
    await signOut()
  }
}
